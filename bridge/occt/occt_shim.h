/* Minimal C interface over OCCT for the panel legend tool.
   No C++ types or exceptions cross this boundary. */
#ifndef OCCT_SHIM_H
#define OCCT_SHIM_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct os_doc os_doc;     /* opaque XDE document */
typedef struct os_solid os_solid; /* opaque solid (or compound of solids) */

enum { OS_OK = 0, OS_ERR = 1 };

enum os_seg_kind { OS_LINE = 1, OS_QUAD = 2, OS_CUBIC = 3, OS_CONIC = 4 };

/* One segment in the z = 0 plane. Uses 2, 3 or 4 points (x, y) by kind.
   OS_CONIC is a rational quadratic: 3 points, the middle one weighted w
   (the ends weigh 1); an arc of a circle stays exact. w is ignored for the
   other kinds. Consecutive segments share end and start points. */
typedef struct {
    int kind;
    double pts[8];
    double w;
} os_segment;

typedef struct {
    const os_segment *segs;
    size_t count;
} os_contour;

/* Last error message for this thread, or "" if none. */
const char *os_last_error(void);

int os_doc_new(os_doc **out);
void os_doc_free(os_doc *doc);

/* Adds one planar face: contours[0] is the outer boundary, the rest are holes.
   Orientation is fixed inside, so contour direction does not matter.
   Returns the face area in *area_out (may be NULL). */
int os_doc_add_face(os_doc *doc, const char *name, const double rgb[3],
                    const os_contour *contours, size_t n_contours, double *area_out);

int os_doc_write_step(os_doc *doc, const char *path);

/* Solids. Each call that makes one returns a new os_solid in *out, to be
   freed with os_solid_free. */

/* The region the contours fill under the even-odd rule (counting outlines
   inward, what lies between an odd one and the even one inside it), swept
   from z0 up to z1. Contours must not cross; their direction does not
   matter. Several outer contours make a compound of solids. */
int os_solid_extrude(const os_contour *contours, size_t n_contours, double z0, double z1, os_solid **out);

/* One face swept from z0 up to z1: contours[0] its outer boundary,
   counter-clockwise, the rest its holes, clockwise, none crossing, all
   already sorted (no containment tests or repairs are made: the fast
   path, for faces from exact 2D booleans). */
int os_solid_extrude_face(const os_contour *contours, size_t n_contours, double z0, double z1, os_solid **out);

/* a with b cut out of it; the overlap of a and b. */
int os_solid_cut(const os_solid *a, const os_solid *b, os_solid **out);
int os_solid_common(const os_solid *a, const os_solid *b, os_solid **out);

/* All of them gathered into one compound, unjoined (they must not overlap). */
int os_solid_compound(const os_solid *const *solids, size_t n, os_solid **out);

/* All of them joined into one (they may overlap). */
int os_solid_fuse(const os_solid *const *solids, size_t n, os_solid **out);

/* Its volume, and whether OCCT's checker finds it valid (1) or not (0).
   Either pointer may be NULL. */
int os_solid_props(const os_solid *s, double *volume, int *valid);

void os_solid_free(os_solid *s);

/* A solid's surface as triangles, for drawing: OCCT's mesher
   (BRepMesh) within `deflection` (mm) and `angle` (radians) of the exact
   surface. Each face's triangles wound with its outward side
   counter-clockwise. `xyz` holds 3 floats a vertex, `idx` 3 a triangle;
   free with os_mesh_free. */
typedef struct {
    float *xyz;
    size_t n_verts;
    unsigned *idx;
    size_t n_tris;
} os_mesh;

int os_solid_mesh(const os_solid *s, double deflection, double angle, os_mesh *out);
void os_mesh_free(os_mesh *m);

/* Adds a solid to the document as one named, coloured part (a copy: the
   solid can be freed afterwards). */
int os_doc_add_solid(os_doc *doc, const char *name, const double rgb[3], const os_solid *s);

#ifdef __cplusplus
}
#endif
#endif
