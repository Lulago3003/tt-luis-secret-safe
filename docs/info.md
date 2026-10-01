## How it works

**LUIS Secret Safe** is a digital safe built only from logic gates and two flip-flops.
When the right 8-bit code is set on the input switches, the safe opens and the
7-segment display spells the owner's name, **L - U - I - S**, one letter per clock cycle.
With any other code the display shows a dash **-** and the decimal point blinks.

The design has three blocks:

1. **Code comparator** (2x NOT + 7x AND): compares `ui[7:0]` against the secret code.
   Its output `OPEN` is 1 only for the correct combination (1 out of 256).
2. **Letter counter**: a 2-bit Johnson counter made with two D flip-flops.
   It cycles through 4 states (00 → 01 → 11 → 10) on every rising edge of `clk`,
   so it needs no reset: any start state is part of the cycle.
3. **Letter decoder** (13 gates): turns the counter state into the segments of
   L, U, I, S and gates them with `OPEN`. When locked it shows `-` and blinks the dot.

| Counter (q1 q0) | Letter | Segments |
|-----------------|--------|----------|
| 0 0             | L      | D E F    |
| 0 1             | U      | B C D E F |
| 1 1             | I      | E F      |
| 1 0             | S      | A C D F G |

## How to test

1. Set the project clock to about **2 Hz** so the letters are easy to read (any frequency works; it is the letter speed).
2. With all switches OFF the display shows `-` and the decimal point blinks: the safe is locked.
3. Set switches 1-8 to **ON OFF ON ON ON OFF ON ON** (`ui_in = 8'b11011101`).
4. The display spells **L, U, I, S** in a loop.
5. Change any switch: the display goes back to `-`.

## External hardware

None. Uses the DIP switches and the 7-segment display on the Tiny Tapeout demo board.
