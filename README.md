![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Flappy Luis - a video game chip for Tiny Tapeout

A complete Flappy-style VGA game made only of digital logic, in a single Tiny Tapeout tile:
640x480 color video, 4 levels that speed up and narrow the gaps, day and starry night,
"GAME OVER" screen, score and best score, sound effects (flap, point, level-up tune, crash),
pixel-perfect collisions, parallax city background and an autopilot demo mode.
Designed by Luis Lasso.

- [Read the datasheet](docs/info.md)
- Play it in your browser: [VGA Playground](https://vga-playground.com/?repo=https://github.com/Lulago3003/tt-luis-secret-safe&ref=flappy-luis)

## Controls

| Input | Function |
|-------|----------|
| `ui[0]` | Flap (every change of the switch is one flap; key `0` in the VGA Playground) |
| `ui[2]` | Flap (push button, one flap per press) |
| `ui[1]` | Autopilot / demo mode (key `1` in the VGA Playground) |

## Levels

| Score | Gap | Speed | Sky |
|-------|-----|-------|-----|
| 0-9   | 128 px | 3 px/frame | day |
| 10-19 | 112 px | 3 px/frame | day |
| 20-29 | 112 px | 4 px/frame | night |
| 30+   | 96 px  | 4 px/frame | night |

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get your
digital and analog designs manufactured on a real chip.

To learn more and get started, visit https://tinytapeout.com.

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)
