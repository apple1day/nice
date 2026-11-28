#include "NICECardboardOptics.h"
#include "polynomial_radial_distortion.h"

NICEOpticalPoint NICECardboardScreenPoint(float x, float y) {
    // Google Cardboard v1 radial coefficients. The movie is head-locked with
    // its optical axis in the center of each half of the phone's display.
    static const cardboard::PolynomialRadialDistortion optics({0.441f, 0.156f});
    const auto screen = optics.DistortInverse({x, y});
    return {screen[0], screen[1]};
}
