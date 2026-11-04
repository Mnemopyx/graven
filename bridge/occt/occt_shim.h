/* Minimal C interface over OCCT for the panel legend tool.
   No C++ types or exceptions cross this boundary. */
#ifndef OCCT_SHIM_H
#define OCCT_SHIM_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct os_doc os_doc; /* opaque XDE document */

enum { OS_OK = 0, OS_ERR = 1 };

enum os_seg_kind { OS_LINE = 1, OS_QUAD = 2, OS_CUBIC = 3 };

/* One segment in the z = 0 plane. Uses 2, 3 or 4 points (x, y) by kind.
   Consecutive segments share end and start points. */
typedef struct {
    int kind;
    double pts[8];
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

#ifdef __cplusplus
}
#endif
#endif
