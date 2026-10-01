## How it works

**Flappy Luis** is a complete Flappy-style video game implemented in hardware. There is no CPU and no
software: every pixel is computed on the fly by logic gates while the VGA beam scans the screen
(640x480 at 60 Hz, 25.175 MHz pixel clock).

![Title screen](title.png)

The game is built from a few hardware blocks:

- **VGA timing** (`hvsync_generator`): horizontal and vertical counters that produce `hsync`, `vsync`
  and the current pixel position.
- **Game logic**, updated once per frame during vertical blanking:
  - the bird has a 9.2 fixed-point height and a signed velocity, with gravity and a flap impulse;
  - two pipes scroll left and respawn on the right with a random gap from a 16-bit LFSR;
  - the score and the best score are kept as BCD digits (0-99);
  - collisions are detected pixel-perfect while drawing: if a bird pixel is drawn on top of a
    pipe pixel during a frame, the bird crashes;
  - a game state machine: title screen, playing, and game over (with a white flash).
- **Renderer**, evaluated for every pixel, from back to front: sky gradient with dithering, clouds,
  a city skyline with lit windows and bushes (scrolling slower than the pipes, for a parallax
  effect), the pipes with caps and shading, the ground with scrolling stripes, the 16x12 bird
  sprite (with an animated wing), and the text ("LUIS" title, score and best score) using a
  3x5 pixel font.
- **Sound**: 1-bit square waves and noise for flapping, scoring and crashing, on `uio[7]`.
- **Autopilot**: when `ui[1]` is high, the chip plays by itself, flapping when the bird falls
  near the bottom of the next gap. Great for demos.

![Gameplay](gameplay.png)

## How to test

Connect a TinyVGA Pmod to the outputs and a VGA monitor, and set the clock to 25.175 MHz
(25.2 MHz also works).

- Title screen: the big "LUIS" title and the best score.
- Flap: press A, B, X, Y, Up or Start on the Gamepad Pmod, or toggle `ui[0]` (every change of
  `ui[0]` is one flap, so a DIP switch or a button both work).
- Fly through the gaps between the pipes. Each pipe you pass is one point.
- When you crash, the screen flashes and the bird falls. Press again to go back to the title.
- `ui[1]` = 1: autopilot (demo mode), the game plays by itself forever.
- `ui[7]` = 1: easy mode (bigger gaps, slower pipes).

You can also play it in the browser with the Tiny Tapeout VGA Playground: open
`https://vga-playground.com/?repo=<this repository URL>`, enable the gamepad and press `a` to flap,
or press `0` on the keyboard.

## External hardware

- [TinyVGA Pmod](https://github.com/mole99/tiny-vga) on the output pins, and a VGA monitor.
- Optional: [Gamepad Pmod](https://github.com/psychogenic/gamepad-pmod) on the input pins.
- Optional: an audio Pmod or a small speaker/amplifier on `uio[7]` for sound.
