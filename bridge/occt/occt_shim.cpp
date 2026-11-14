#include "occt_shim.h"

#include <BRepAdaptor_Curve.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRep_Builder.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>
#include <vector>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <Geom_BezierCurve.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Precision.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <STEPControl_StepModelType.hxx>
#include <ShapeFix_Face.hxx>
#include <Standard_Failure.hxx>
#include <NCollection_Array1.hxx>
#include <gp_Pnt.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Wire.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Pln.hxx>

#include <exception>
#include <string>

struct os_doc {
    Handle(TDocStd_Document) doc;
};

struct os_solid {
    TopoDS_Shape shape;
};

static thread_local std::string g_err;

static int fail(const std::string &msg) {
    g_err = msg;
    return OS_ERR;
}

// Every entry point runs its body through this, so no exception reaches Zig.
template <class F> static int guarded(F &&body) {
    g_err.clear();
    try {
        return body();
    } catch (const Standard_Failure &e) {
        return fail(std::string("OCCT: ") + e.what());
    } catch (const std::exception &e) {
        return fail(std::string("C++: ") + e.what());
    } catch (...) {
        return fail("unknown C++ exception");
    }
}

extern "C" const char *os_last_error(void) { return g_err.c_str(); }

// Libraries never write to the console, so drop OCCT's default stdout printer once.
static void silence_occt() {
    static const bool done = [] {
        Message::DefaultMessenger()->ChangePrinters().Clear();
        return true;
    }();
    (void)done;
}

extern "C" int os_doc_new(os_doc **out) {
    return guarded([&]() -> int {
        silence_occt();
        Handle(XCAFApp_Application) app = XCAFApp_Application::GetApplication();
        auto *d = new os_doc;
        app->NewDocument("MDTV-XCAF", d->doc);
        *out = d;
        return OS_OK;
    });
}

extern "C" void os_doc_free(os_doc *doc) {
    if (!doc) return;
    try {
        XCAFApp_Application::GetApplication()->Close(doc->doc);
    } catch (...) {
    }
    delete doc;
}

static bool make_wire(const os_contour &c, TopoDS_Wire &wire, std::string &why) {
    BRepBuilderAPI_MakeWire mw;
    for (size_t i = 0; i < c.count; ++i) {
        const os_segment &s = c.segs[i];
        int npts = s.kind == OS_LINE ? 2 : (s.kind == OS_QUAD || s.kind == OS_CONIC) ? 3 : s.kind == OS_CUBIC ? 4 : 0;
        if (npts == 0) {
            why = "segment " + std::to_string(i) + ": bad kind";
            return false;
        }
        NCollection_Array1<gp_Pnt> poles(1, npts);
        for (int k = 0; k < npts; ++k) poles.SetValue(k + 1, gp_Pnt(s.pts[2 * k], s.pts[2 * k + 1], 0.0));
        // OCCT accepts a curve whose control points all coincide, so check here.
        bool degenerate = true;
        for (int k = 2; k <= npts; ++k)
            if (poles(k).Distance(poles(1)) > Precision::Confusion()) degenerate = false;
        if (degenerate) {
            why = "segment " + std::to_string(i) + ": degenerate (zero length)";
            return false;
        }
        Handle(Geom_BezierCurve) curve;
        if (s.kind == OS_CONIC) {
            if (!(s.w > 0)) {
                why = "segment " + std::to_string(i) + ": conic weight must be positive";
                return false;
            }
            NCollection_Array1<double> weights(1, 3);
            weights.SetValue(1, 1.0);
            weights.SetValue(2, s.w);
            weights.SetValue(3, 1.0);
            curve = new Geom_BezierCurve(poles, weights);
        } else {
            curve = new Geom_BezierCurve(poles);
        }
        BRepBuilderAPI_MakeEdge me(curve);
        if (!me.IsDone()) {
            why = "segment " + std::to_string(i) + ": degenerate edge";
            return false;
        }
        mw.Add(me.Edge());
        if (!mw.IsDone()) {
            why = "segment " + std::to_string(i) + ": does not connect";
            return false;
        }
    }
    if (!mw.Wire().Closed()) {
        why = "contour is not closed";
        return false;
    }
    wire = mw.Wire();
    return true;
}

extern "C" int os_doc_add_face(os_doc *doc, const char *name, const double rgb[3],
                               const os_contour *contours, size_t n_contours, double *area_out) {
    return guarded([&]() -> int {
        if (n_contours == 0) return fail("no contours");
        std::string why;
        TopoDS_Wire outer;
        if (!make_wire(contours[0], outer, why)) return fail("contour 0: " + why);
        BRepBuilderAPI_MakeFace mf(gp_Pln(gp::XOY()), outer, true);
        for (size_t i = 1; i < n_contours; ++i) {
            TopoDS_Wire hole;
            if (!make_wire(contours[i], hole, why)) return fail("contour " + std::to_string(i) + ": " + why);
            mf.Add(hole);
        }
        if (!mf.IsDone()) return fail("face construction failed");

        // Orient outer and hole wires from containment, not input direction.
        ShapeFix_Face fix(mf.Face());
        fix.FixOrientation();
        fix.Perform();
        TopoDS_Face face = fix.Face();

        GProp_GProps props;
        BRepGProp::SurfaceProperties(face, props);
        if (area_out) *area_out = props.Mass();

        Handle(XCAFDoc_ShapeTool) shapes = XCAFDoc_DocumentTool::ShapeTool(doc->doc->Main());
        Handle(XCAFDoc_ColorTool) colors = XCAFDoc_DocumentTool::ColorTool(doc->doc->Main());
        TDF_Label label = shapes->AddShape(face, false);
        TDataStd_Name::Set(label, TCollection_ExtendedString(name, true));
        colors->SetColor(label, Quantity_Color(rgb[0], rgb[1], rgb[2], Quantity_TOC_sRGB), XCAFDoc_ColorSurf);
        return OS_OK;
    });
}

extern "C" int os_doc_write_step(os_doc *doc, const char *path) {
    return guarded([&]() -> int {
        STEPCAFControl_Writer w;
        w.SetColorMode(true);
        w.SetNameMode(true);
        if (!w.Transfer(doc->doc, STEPControl_AsIs)) return fail("STEP transfer failed");
        if (w.Write(path) != IFSelect_RetDone) return fail("STEP write failed");
        return OS_OK;
    });
}

// Solids ---------------------------------------------------------------------

// A planar face bounded by one wire, oriented from its geometry.
static TopoDS_Face plain_face(const TopoDS_Wire &w) {
    BRepBuilderAPI_MakeFace mf(gp_Pln(gp::XOY()), w, true);
    ShapeFix_Face fix(mf.Face());
    fix.FixOrientation();
    fix.Perform();
    return fix.Face();
}

// A point on the wire (the middle of its first edge).
static gp_Pnt point_on(const TopoDS_Wire &w) {
    TopExp_Explorer ex(w, TopAbs_EDGE);
    BRepAdaptor_Curve c(TopoDS::Edge(ex.Current()));
    return c.Value((c.FirstParameter() + c.LastParameter()) / 2);
}

extern "C" int os_solid_extrude(const os_contour *contours, size_t n, double z0, double z1, os_solid **out) {
    return guarded([&]() -> int {
        if (n == 0) return fail("no contours");
        if (!(z1 > z0)) return fail("z1 must be above z0");
        std::vector<TopoDS_Wire> wires(n);
        std::vector<TopoDS_Face> faces(n);
        for (size_t i = 0; i < n; ++i) {
            std::string why;
            if (!make_wire(contours[i], wires[i], why)) return fail("contour " + std::to_string(i) + ": " + why);
            faces[i] = plain_face(wires[i]);
        }
        // How deep each contour lies (how many others enclose it), and its
        // parent: the deepest of those.
        std::vector<int> depth(n, 0);
        std::vector<long> parent(n, -1);
        for (size_t i = 0; i < n; ++i) {
            gp_Pnt p = point_on(wires[i]);
            for (size_t j = 0; j < n; ++j) {
                if (i == j) continue;
                BRepClass_FaceClassifier cls(faces[j], p, Precision::Confusion());
                if (cls.State() == TopAbs_IN) depth[i]++;
            }
        }
        for (size_t i = 0; i < n; ++i) {
            if (depth[i] == 0) continue;
            gp_Pnt p = point_on(wires[i]);
            for (size_t j = 0; j < n; ++j) {
                if (i == j || depth[j] != depth[i] - 1) continue;
                BRepClass_FaceClassifier cls(faces[j], p, Precision::Confusion());
                if (cls.State() == TopAbs_IN) parent[i] = (long)j;
            }
        }
        // Each outer contour (even depth) with its holes (its children),
        // swept up.
        gp_Trsf lift;
        lift.SetTranslation(gp_Vec(0, 0, z0));
        BRep_Builder bb;
        TopoDS_Compound all;
        bb.MakeCompound(all);
        int solids = 0;
        for (size_t i = 0; i < n; ++i) {
            if (depth[i] % 2 != 0) continue;
            TopoDS_Face base = faces[i];
            bool holes = false;
            BRepBuilderAPI_MakeFace mf(faces[i]);
            for (size_t k = 0; k < n; ++k)
                if (parent[k] == (long)i) {
                    mf.Add(wires[k]);
                    holes = true;
                }
            if (holes) {
                if (!mf.IsDone()) return fail("contour " + std::to_string(i) + ": face with holes failed");
                ShapeFix_Face fix(mf.Face());
                fix.FixOrientation();
                fix.Perform();
                base = fix.Face();
            }
            TopoDS_Shape face = BRepBuilderAPI_Transform(base, lift, true).Shape();
            BRepPrimAPI_MakePrism prism(face, gp_Vec(0, 0, z1 - z0));
            if (!prism.IsDone()) return fail("contour " + std::to_string(i) + ": sweep failed");
            bb.Add(all, prism.Shape());
            solids++;
        }
        if (solids == 0) return fail("no outer contour");
        *out = new os_solid{all};
        return OS_OK;
    });
}

template <class Op> static int boolean(const os_solid *a, const os_solid *b, os_solid **out, const char *what) {
    return guarded([&]() -> int {
        Op op(a->shape, b->shape);
        if (!op.IsDone() || op.HasErrors()) return fail(std::string(what) + " failed");
        *out = new os_solid{op.Shape()};
        return OS_OK;
    });
}

extern "C" int os_solid_cut(const os_solid *a, const os_solid *b, os_solid **out) {
    return boolean<BRepAlgoAPI_Cut>(a, b, out, "cut");
}

extern "C" int os_solid_common(const os_solid *a, const os_solid *b, os_solid **out) {
    return boolean<BRepAlgoAPI_Common>(a, b, out, "common");
}

extern "C" int os_solid_props(const os_solid *s, double *volume, int *valid) {
    return guarded([&]() -> int {
        if (volume) {
            GProp_GProps props;
            BRepGProp::VolumeProperties(s->shape, props);
            *volume = props.Mass();
        }
        if (valid) *valid = BRepCheck_Analyzer(s->shape).IsValid() ? 1 : 0;
        return OS_OK;
    });
}

extern "C" void os_solid_free(os_solid *s) { delete s; }

extern "C" int os_doc_add_solid(os_doc *doc, const char *name, const double rgb[3], const os_solid *s) {
    return guarded([&]() -> int {
        Handle(XCAFDoc_ShapeTool) shapes = XCAFDoc_DocumentTool::ShapeTool(doc->doc->Main());
        Handle(XCAFDoc_ColorTool) colors = XCAFDoc_DocumentTool::ColorTool(doc->doc->Main());
        TDF_Label label = shapes->AddShape(s->shape, false);
        TDataStd_Name::Set(label, TCollection_ExtendedString(name, true));
        Quantity_Color c(rgb[0], rgb[1], rgb[2], Quantity_TOC_sRGB);
        colors->SetColor(label, c, XCAFDoc_ColorGen);
        colors->SetColor(label, c, XCAFDoc_ColorSurf);
        return OS_OK;
    });
}
