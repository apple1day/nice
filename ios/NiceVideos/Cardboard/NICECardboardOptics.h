#ifndef NICE_CARDBOARD_OPTICS_H
#define NICE_CARDBOARD_OPTICS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x;
    float y;
} NICEOpticalPoint;

// Center-relative tan-angle coordinates of the flat movie -> physical display.
NICEOpticalPoint NICECardboardScreenPoint(float x, float y);

#ifdef __cplusplus
}
#endif
#endif
