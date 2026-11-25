// THE LIFE A BOARD HAS, BY THE PANELS ON IT (outcome.c lifeOf), in frames: made by material.c from 120 games of 5 runs (39137780746, 39137784697, 39137788159, 39137792044, gambit),
// 29 lost -- never by hand. A row's worth of panels a bin, its frames over its losses (a loss not yet seen counted as one), drawn
// straight between the bins' middles:
//    0- 5      3113 frames    0 lost
//    6-11     44032 frames    4 lost
//   12-17    116008 frames    4 lost
//   18-23    219329 frames    1 lost
//   24-29    313735 frames    1 lost
//   30-35    371887 frames    0 lost
//   36-41    347647 frames    0 lost
//   42-47    309663 frames    2 lost
//   48-53    272011 frames    1 lost
//   54-59    180894 frames    6 lost
//   60-65     74253 frames    6 lost
//   66-71      5736 frames    4 lost
//   72-77         0 frames    0 lost
#define LIFEMAX 72
static const int32_t LIFE[LIFEMAX + 1] = {
  3113, 3113, 3113, 3771, 5087, 6403, 7718, 9034, 10350, 12508, 15507, 18506,
  21505, 24504, 27503, 44863, 76584, 108305, 140026, 171747, 203468, 227196, 242931, 258665,
  274399, 290134, 305868, 318581, 328273, 337965, 347657, 357349, 367041, 369867, 365827, 361787,
  357747, 353707, 349667, 331579, 299443, 267307, 235171, 203035, 170899, 164596, 184126, 203656,
  223186, 242716, 262246, 251856, 211546, 171235, 130925, 90615, 50304, 28668, 25706, 22743,
  19781, 16819, 13857, 11464, 9640, 7817, 5993, 4169, 2346, 1434, 1434, 1434,
  1434
};
