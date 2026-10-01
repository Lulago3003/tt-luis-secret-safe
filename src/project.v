/*
 * Flappy Luis - a Flappy-style VGA game for Tiny Tapeout
 *
 * Copyright (c) 2026 Luis Lasso
 * SPDX-License-Identifier: Apache-2.0
 *
 * Video: TinyVGA Pmod on uo_out (640x480 @ 60 Hz, 25.175 MHz clock).
 * Audio: 1-bit sound on uio_out[7] (TT Audio Pmod).
 * Input: ui_in[0] = flap on every change (switch), ui_in[2] = flap button (press),
 *        ui_in[1] = autopilot (demo mode).
 */

`default_nettype none

module tt_um_lulago3003_flappy (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam [1:0] S_READY = 2'd0, S_PLAY = 2'd1, S_DEAD = 2'd2;

  localparam [9:0] GROUND_Y    = 10'd416;   // first ground line
  localparam [10:0] BIRD_YMAX  = 11'd1568;  // (416 - 24) * 4, bird resting on the ground
  localparam signed [6:0] FLAP_VEL = -7'sd22;  // quarter pixels per frame
  localparam signed [6:0] MAX_VEL  = 7'sd32;

  // ---------------------------------------------------------------------------
  // VGA timing
  // ---------------------------------------------------------------------------
  wire hsync, vsync, video_active;
  wire [9:0] pix_x, pix_y;
  reg [1:0] R, G, B;

  assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};

  hvsync_generator vga_sync_gen (
      .clk(clk),
      .reset(~rst_n),
      .hsync(hsync),
      .vsync(vsync),
      .display_on(video_active),
      .hpos(pix_x),
      .vpos(pix_y)
  );

  wire frame_tick = (pix_y == 10'd480) && (pix_x == 10'd0);
  wire line_tick = (pix_x == 10'd0);

  // ---------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------
  wire autopilot = ui_in[1];
  wire _unused = &{ena, uio_in, ui_in[7:3], 1'b0};

  // ---------------------------------------------------------------------------
  // Game state
  // ---------------------------------------------------------------------------
  reg [1:0] state;
  reg [10:0] bird_yf;          // 9.2 fixed point
  reg signed [6:0] vel;        // quarter pixels per frame, positive = down
  // The two pipes are always 352 px apart: pipe A is at xs = phase, pipe B at phase + 352
  // (xs = screen x + 64). When A leaves the screen, B becomes A and a new B appears.
  reg [8:0] phase;             // 0..351
  reg [7:0] gap_a, gap_b;      // gap top line (the gap is 128 px tall)
  reg vis_a, vis_b;            // the pipe is in play
  reg passed_a;                // the bird already flew through pipe A
  reg [3:0] score_lo, score_hi, best_lo, best_hi;
  reg [8:0] bg_scroll;         // frame counter, also the background parallax scroll
  reg [9:0] lfsr;
  reg [5:0] dead_timer;
  reg hit;
  reg sw_prev, btn_prev;
  wire bird_opaque, pipe_on;  // from the renderer, used for collisions

  wire [5:0] frame = bg_scroll[5:0];
  wire [4:0] scroll = bg_scroll[4:0] + {bg_scroll[3:0], 1'b0};  // ground: 3 px per frame
  wire [8:0] bird_y = bird_yf[10:2];

  // New gap: 48 + 3 * random(0..63)
  wire [5:0] rnd = lfsr[5:0];
  wire [7:0] new_gap = 8'd48 + {2'b00, rnd} + {1'b0, rnd, 1'b0};

  // Pipe A passes the bird when its right edge (phase - 4 in screen x + 64) is left of x = 160
  wire a_ahead = vis_a & ~passed_a;
  wire scores = a_ahead & (phase < 9'd164);
  wire wrap = (phase < 9'd3);

  // Autopilot: flap when the bird drops near the bottom of the next gap (gap + 128 - 44)
  wire [7:0] next_gap = a_ahead ? gap_a : gap_b;
  wire [8:0] auto_line = {1'b0, next_gap} + 9'd84;
  wire auto_flap = autopilot & ~vel[6] & (bird_y >= auto_line);

  wire press = (ui_in[0] ^ sw_prev) | (ui_in[2] & ~btn_prev);

  // Physics
  wire signed [12:0] y_next = $signed({2'b00, bird_yf}) + {{6{vel[6]}}, vel};
  wire y_floor = (y_next >= $signed({2'b00, BIRD_YMAX}));
  wire signed [6:0] vel_fall = (vel < MAX_VEL) ? vel + 7'sd1 : vel;

  // Score with BCD increment (saturates at 99)
  wire [3:0] score_lo_inc = (score_lo == 4'd9) ? ((score_hi == 4'd9) ? 4'd9 : 4'd0) : score_lo + 4'd1;
  wire [3:0] score_hi_inc = (score_lo == 4'd9 && score_hi != 4'd9) ? score_hi + 4'd1 : score_hi;
  wire new_best = {score_hi, score_lo} > {best_hi, best_lo};

  // Sound
  localparam [1:0] SND_FLAP = 2'd1, SND_SCORE = 2'd2, SND_HIT = 2'd3;
  reg [1:0] snd_type;
  reg [4:0] snd_timer;
  reg noise;

  always @(posedge clk) begin
    if (~rst_n) begin
      state      <= S_READY;
      bird_yf    <= 11'd800;
      vel        <= 7'sd0;
      phase      <= 9'd351;
      gap_a      <= 8'd120;
      gap_b      <= 8'd160;
      vis_a      <= 1'b0;
      vis_b      <= 1'b0;
      passed_a   <= 1'b0;
      score_lo   <= 4'd0;
      score_hi   <= 4'd0;
      best_lo    <= 4'd0;
      best_hi    <= 4'd0;
      bg_scroll  <= 9'd0;
      lfsr       <= 10'h2E1;
      dead_timer <= 6'd0;
      hit        <= 1'b0;
      sw_prev    <= 1'b0;
      btn_prev   <= 1'b0;
      snd_type   <= 2'd0;
      snd_timer  <= 5'd0;
    end else begin
      // Free-running LFSR: the player's timing makes the pipes random
      lfsr <= {lfsr[8:0], lfsr[9] ^ lfsr[6]};

      // Collision: a bird pixel drawn on top of a pipe pixel
      if (bird_opaque && pipe_on && video_active) hit <= 1'b1;

      if (frame_tick) begin
        hit      <= 1'b0;
        sw_prev  <= ui_in[0];
        btn_prev <= ui_in[2];
        if (snd_timer != 5'd0) snd_timer <= snd_timer - 5'd1;
        if (state != S_DEAD) bg_scroll <= bg_scroll + 9'd1;

        case (state)
          S_READY: begin
            // Bird bobs up and down while waiting
            bird_yf <= {2'b00, 9'd200 + {5'd0, frame[5] ? frame[4:1] : ~frame[4:1]}} << 2;
            if (press || (autopilot && frame == 6'd0)) begin
              state     <= S_PLAY;
              vel       <= FLAP_VEL;
              phase     <= 9'd351;   // pipe B enters at the right edge, pipe A is not used yet
              gap_b     <= new_gap;
              vis_a     <= 1'b0;
              vis_b     <= 1'b1;
              passed_a  <= 1'b0;
              score_lo  <= 4'd0;
              score_hi  <= 4'd0;
              snd_type  <= SND_FLAP;
              snd_timer <= 5'd8;
            end
          end

          S_PLAY: begin
            // Pipes scroll left; when pipe A leaves the screen, B becomes A and a new B appears
            if (wrap) begin
              phase    <= phase + 9'd349;
              gap_a    <= gap_b;
              gap_b    <= new_gap;
              vis_a    <= vis_b;
              passed_a <= 1'b0;
            end else begin
              phase <= phase - 9'd3;
            end

            if (scores) begin
              passed_a  <= 1'b1;
              score_lo  <= score_lo_inc;
              score_hi  <= score_hi_inc;
              snd_type  <= SND_SCORE;
              snd_timer <= 5'd12;
            end

            // Bird physics
            if (press || auto_flap) begin
              vel <= FLAP_VEL;
              if (!scores) begin
                snd_type  <= SND_FLAP;
                snd_timer <= 5'd8;
              end
            end else begin
              vel <= vel_fall;
            end

            if (y_next < 0) bird_yf <= 11'd0;
            else if (y_floor) bird_yf <= BIRD_YMAX;
            else bird_yf <= y_next[10:0];

            if (hit || y_floor) begin
              state      <= S_DEAD;
              dead_timer <= 6'd0;
              vel        <= 7'sd0;
              snd_type   <= SND_HIT;
              snd_timer  <= 5'd24;
              if (new_best) begin
                best_lo <= score_lo;
                best_hi <= score_hi;
              end
            end
          end

          default: begin  // S_DEAD: the bird drops to the ground
            if (dead_timer != 6'd63) dead_timer <= dead_timer + 6'd1;
            vel <= vel_fall;
            if (y_floor) bird_yf <= BIRD_YMAX;
            else if (y_next >= 0) bird_yf <= y_next[10:0];
            if (dead_timer == 6'd63 && (press || autopilot)) begin
              state <= S_READY;
              vel   <= 7'sd0;
            end
          end
        endcase
      end
    end
  end

  // Sound generator. The scanline counter is a free clock divider: pix_y[k] is a square
  // wave of 31469 / 2^(k+1) Hz. Flap: 492 Hz -> 983 Hz chirp. Score: 983 Hz -> 1967 Hz.
  // Crash: noise from the LFSR, sampled once per line.
  always @(posedge clk) begin
    if (~rst_n) noise <= 1'b0;
    else if (line_tick) noise <= lfsr[0];
  end
  wire tone = (snd_type == SND_FLAP) ? (snd_timer[2] ? pix_y[5] : pix_y[4]) :
                                       (snd_timer[3] ? pix_y[4] : pix_y[3]);

  wire sound = (snd_timer != 5'd0) & ((snd_type == SND_HIT) ? noise : tone);
  assign uio_out = {sound, 7'b0};
  assign uio_oe  = 8'b1000_0000;

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------
  wire [10:0] xs = {1'b0, pix_x} + 11'd64;

  // Pipes: they are 352 px apart, so at most one of them is under the beam.
  // Pick it, then draw it with a single shared renderer.
  wire [10:0] lxa = xs - {2'b00, phase};
  wire [10:0] lxb = lxa - 11'd352;
  wire near_a = vis_a && (lxa[10:6] == 5'd0);
  wire near_b = vis_b && (lxb[10:6] == 5'd0);
  wire [5:0] p_lx = near_a ? lxa[5:0] : lxb[5:0];
  wire [7:0] p_gap = near_a ? gap_a : gap_b;
  wire p_on;
  wire [5:0] pipe_color;
  pipe_pixel pipe (
      .lx(p_lx), .near(near_a | near_b), .y(pix_y), .gap_top(p_gap),
      .on(p_on), .color(pipe_color)
  );
  assign pipe_on = (state != S_READY) & p_on;

  // Bird sprite: 16x12 pixels, drawn at 2x (32x24), at x = 160 = 5 * 32.
  wire [9:0] bdy = pix_y - {1'b0, bird_y};
  wire in_bird = (pix_x[9:5] == 5'd5) && (bdy < 10'd24);
  wire [3:0] b_row = bdy[4:1];
  wire [3:0] b_col = pix_x[4:1];
  wire [1:0] bird_idx;
  bird_sprite sprite (
      .row(b_row),
      .col(b_col),
      .idx(bird_idx)
  );
  assign bird_opaque = in_bird && (bird_idx != 2'd0);
  wire bird_orange = (b_row >= 4'd6) && (b_col >= 4'd10);
  wire [5:0] bird_color = (bird_idx == 2'd1) ? 6'b00_00_00 :
                          (bird_idx == 2'd2) ? 6'b11_11_00 :
                          bird_orange ? 6'b11_01_00 : 6'b11_11_11;

  // Text: title "LUIS", score and best score, all with one 3x5 font.
  // Positions are aligned so that glyph coordinates are plain bit slices.
  // Title: x 192..431 (4 slots of 64 px, letters 48 px wide), y 96..175, 16x scale
  wire in_title = (state == S_READY) && (pix_x >= 10'd192) && (pix_x < 10'd432) &&
                  (pix_y >= 10'd96) && (pix_y < 10'd176) && (pix_x[5:4] != 2'd3);
  // Score: x 288..343 (2 slots of 32 px), y 24..63, 8x scale
  wire in_score = (state != S_READY) && (pix_x >= 10'd288) && (pix_x < 10'd344) &&
                  (pix_y >= 10'd24) && (pix_y < 10'd64) && (pix_x[4:3] != 2'd3) &&
                  (~pix_x[5] || score_hi != 4'd0);
  // Best: x 304..331 (2 slots of 16 px), y 200..219, 4x scale
  wire in_best = (state != S_PLAY) && (pix_x >= 10'd304) && (pix_x < 10'd332) &&
                 (pix_y >= 10'd200) && (pix_y < 10'd220) && (pix_x[3:2] != 2'd3);

  reg [3:0] glyph;
  reg [2:0] g_row;
  reg [1:0] g_col;
  always @(*) begin
    if (in_title) begin
      case (pix_x[7:6])
        2'd3: glyph = 4'd10;  // L (x 192..255)
        2'd0: glyph = 4'd11;  // U (x 256..319)
        2'd1: glyph = 4'd12;  // I (x 320..383)
        default: glyph = 4'd5;  // S (x 384..447)
      endcase
      g_row = pix_y[6:4] - 3'd6;
      g_col = pix_x[5:4];
    end else if (in_score) begin
      glyph = pix_x[5] ? score_hi : score_lo;
      g_row = pix_y[5:3] - 3'd3;
      g_col = pix_x[4:3];
    end else begin
      glyph = pix_x[4] ? best_hi : best_lo;
      g_row = pix_y[4:2] - 3'd2;
      g_col = pix_x[3:2];
    end
  end

  wire font_on;
  font_3x5 font (
      .glyph(glyph),
      .row(g_row),
      .col(g_col),
      .on(font_on)
  );
  wire text_on = (in_title | in_score | in_best) & font_on;
  wire [5:0] text_color = in_title ? 6'b11_10_00 : in_best ? 6'b11_01_00 : 6'b11_11_11;

  // Ground with scrolling stripes
  wire [4:0] gx = pix_x[4:0] + scroll;
  wire [4:0] gd = gx + pix_y[4:0];
  wire in_ground = (pix_y >= GROUND_Y);
  // Lines 416..431 (pix_y[9:4] = 26): black edge, striped grass, dark grass. Then dirt.
  reg [5:0] ground_color;
  always @(*) begin
    if (pix_y[9:4] == 6'd26) begin
      case (pix_y[3:2])
        2'd0: ground_color = 6'b00_00_00;
        2'd3: ground_color = 6'b01_10_00;
        default: ground_color = gx[3] ? 6'b01_11_00 : 6'b10_11_00;
      endcase
    end else begin
      ground_color = gd[4] ? 6'b11_10_01 : 6'b10_10_01;
    end
  end

  // Sky gradient with dithering
  wire dither = pix_x[0] ^ pix_y[0];
  wire [5:0] sky_color = (pix_y < 10'd192) ? 6'b01_10_11 :
                         (pix_y < 10'd288) ? (dither ? 6'b01_10_11 : 6'b10_11_11) : 6'b10_11_11;

  // Background layers, scrolling slower than the pipes (parallax)
  wire [8:0] bgx = pix_x[8:0] + bg_scroll;
  // Clouds: a bumpy white band behind the city, from y = 304
  wire [4:0] cloud_bump = bgx[5] ? bgx[4:0] : ~bgx[4:0];
  wire in_cloud = (pix_y >= 10'd320) || ((pix_y[9:4] == 6'd19) && (pix_y[3:0] >= cloud_bump[4:1]));
  // City skyline: 32 px wide buildings with lit windows. top = first 8-px row of each building.
  reg [5:0] top;
  always @(*) begin
    case (bgx[8:5])
      4'd0: top = 6'd47;   4'd1: top = 6'd44;   4'd2: top = 6'd46;   4'd3: top = 6'd42;
      4'd4: top = 6'd48;   4'd5: top = 6'd45;   4'd6: top = 6'd41;   4'd7: top = 6'd46;
      4'd8: top = 6'd43;   4'd9: top = 6'd47;   4'd10: top = 6'd45;  4'd11: top = 6'd40;
      4'd12: top = 6'd44;  4'd13: top = 6'd46;  4'd14: top = 6'd42;  default: top = 6'd45;
    endcase
  end
  wire in_city = (pix_y[9:3] >= {1'b0, top}) && (bgx[4:1] != 4'd0);
  wire city_window = (bgx[2:1] == 2'b10) && (pix_y[2:1] == 2'b01) && (bgx[4:3] != 2'b00);
  // Bushes in front of the city, from y = 392
  wire [5:0] bbx = pix_x[5:0] + {bg_scroll[4:0], 1'b0};
  wire [4:0] bush_bump = bbx[5] ? bbx[4:0] : ~bbx[4:0];
  wire in_bush = (pix_y[9:3] >= 7'd50) || ((pix_y[9:3] == 7'd49) && (pix_y[2:0] >= bush_bump[4:2]));

  wire [5:0] bg_color = in_bush ? (dither ? 6'b00_10_00 : 6'b01_11_01) :
                        in_city ? (city_window ? 6'b11_11_10 : 6'b01_10_10) :
                        in_cloud ? 6'b11_11_11 : sky_color;

  wire flash = (state == S_DEAD) && (dead_timer < 6'd4);

  wire [5:0] color = flash       ? 6'b11_11_11 :
                     text_on     ? text_color :
                     bird_opaque ? bird_color :
                     pipe_on     ? pipe_color :
                     in_ground   ? ground_color : bg_color;

  always @(posedge clk) begin
    if (~rst_n) begin
      R <= 2'd0;
      G <= 2'd0;
      B <= 2'd0;
    end else if (video_active) begin
      {R, G, B} <= color;
    end else begin
      {R, G, B} <= 6'd0;
    end
  end

endmodule

// -----------------------------------------------------------------------------
// One pipe column (top and bottom halves with caps, 128 px gap).
// lx = x inside the pipe (0..63), near = the pipe is within 64 px.
// -----------------------------------------------------------------------------
module pipe_pixel (
    input  wire [5:0] lx,
    input  wire       near,
    input  wire [9:0] y,
    input  wire [7:0] gap_top,
    output wire       on,
    output wire [5:0] color
);
  wire in_x = near && (lx[5:2] != 4'd15);  // 0 <= lx < 60

  // Vertical position relative to the gap (two's complement, 10 bits)
  wire [9:0] dt = y - {2'b00, gap_top};    // y - gap top
  wire [9:0] db = dt - 10'd128;            // y - gap bottom
  wire top_cap  = dt[9] && (dt[8:5] == 4'b1111) && (dt[4:3] != 2'b00);  // -24 <= dt < 0
  wire top_body = dt[9] && !top_cap;
  wire bot_cap  = !db[9] && (db[9:5] == 5'd0) && (db[4:3] != 2'b11);    // 0 <= db < 24
  wire bot_body = !db[9] && !bot_cap && (y < 10'd416);

  wire body_x = (lx >= 6'd4) && (lx < 6'd56);
  wire in_cap  = in_x && (top_cap || bot_cap);
  wire in_body = in_x && body_x && (top_body || bot_body);
  assign on = in_cap || in_body;

  // Black outline, 2 px
  wire [4:0] cy = top_cap ? dt[4:0] : db[4:0];  // 8..31 for the top cap, 0..23 for the bottom cap
  wire cap_edge = (lx < 6'd2) || (lx >= 6'd58) ||
                  (top_cap && ((cy < 5'd10) || (cy >= 5'd30))) ||
                  (bot_cap && ((cy < 5'd2) || (cy >= 5'd22)));
  wire body_edge = (lx < 6'd6) || (lx >= 6'd54);
  wire edge_px = in_cap ? cap_edge : body_edge;

  assign color = edge_px      ? 6'b00_00_00 :
                 (lx < 6'd12) ? 6'b01_11_01 :
                 (lx < 6'd18) ? 6'b10_11_10 :
                 (lx < 6'd44) ? 6'b00_10_00 : 6'b00_01_00;
endmodule

// -----------------------------------------------------------------------------
// Bird sprite, 16x12, 2 bits per pixel:
// 0 = transparent, 1 = black, 2 = yellow, 3 = white (orange on the beak)
// -----------------------------------------------------------------------------
module bird_sprite (
    input  wire [3:0] row,
    input  wire [3:0] col,
    output wire [1:0] idx
);
  reg [31:0] bits;
  always @(*) begin
    case (row)
      4'd0:  bits = 32'b00_00_00_00_00_01_01_01_01_01_01_00_00_00_00_00;  // .....kkkkkk.....
      4'd1:  bits = 32'b00_00_00_01_01_10_10_10_10_01_11_11_01_00_00_00;  // ...kkyyyykwwk...
      4'd2:  bits = 32'b00_00_01_10_10_10_10_10_10_01_11_11_11_01_00_00;  // ..kyyyyyykwwwk..
      4'd3:  bits = 32'b00_01_10_10_10_10_10_10_10_01_11_11_01_11_01_00;  // .kyyyyyyykwwkwk.
      4'd4:  bits = 32'b01_01_01_01_10_10_10_10_10_01_11_11_01_11_01_00;  // kkkkyyyyykwwkwk.
      4'd5:  bits = 32'b01_11_11_11_11_01_10_10_10_10_01_11_11_11_01_00;  // kwwwwkyyyykwwwk.
      4'd6:  bits = 32'b01_11_11_11_11_11_01_10_10_10_10_01_01_01_01_01;  // kwwwwwkyyyykkkkk
      4'd7:  bits = 32'b01_11_11_11_11_01_10_10_10_10_01_11_11_11_11_01;  // kwwwwkyyyykwwwwk
      4'd8:  bits = 32'b00_01_01_01_01_10_10_10_10_10_10_01_01_01_01_01;  // .kkkkyyyyyykkkkk
      4'd9:  bits = 32'b00_01_10_10_10_10_10_10_10_10_01_11_11_11_01_00;  // .kyyyyyyyykwwwk.
      4'd10: bits = 32'b00_00_01_01_10_10_10_10_10_10_10_01_01_01_00_00;  // ..kkyyyyyyykkk..
      4'd11: bits = 32'b00_00_00_00_01_01_01_01_01_01_01_00_00_00_00_00;  // ....kkkkkkk.....
      default: bits = 32'd0;
    endcase
  end
  wire [4:0] shift = {~col, 1'b0};  // col 0 is the most significant pair
  wire [31:0] shifted = bits >> shift;
  assign idx = shifted[1:0];
endmodule

// -----------------------------------------------------------------------------
// 3x5 font: digits 0-9, then L, U, I
// -----------------------------------------------------------------------------
module font_3x5 (
    input  wire [3:0] glyph,
    input  wire [2:0] row,
    input  wire [1:0] col,
    output wire       on
);
  reg [14:0] g;
  always @(*) begin
    case (glyph)
      4'd0:  g = 15'b111_101_101_101_111;
      4'd1:  g = 15'b010_110_010_010_111;
      4'd2:  g = 15'b111_001_111_100_111;
      4'd3:  g = 15'b111_001_111_001_111;
      4'd4:  g = 15'b101_101_111_001_001;
      4'd5:  g = 15'b111_100_111_001_111;
      4'd6:  g = 15'b111_100_111_101_111;
      4'd7:  g = 15'b111_001_001_001_001;
      4'd8:  g = 15'b111_101_111_101_111;
      4'd9:  g = 15'b111_101_111_001_111;
      4'd10: g = 15'b100_100_100_100_111;  // L
      4'd11: g = 15'b101_101_101_101_111;  // U
      4'd12: g = 15'b111_010_010_010_111;  // I
      default: g = 15'd0;
    endcase
  end
  reg [2:0] line;
  always @(*) begin
    case (row)
      3'd0: line = g[14:12];
      3'd1: line = g[11:9];
      3'd2: line = g[8:6];
      3'd3: line = g[5:3];
      default: line = g[2:0];
    endcase
  end
  assign on = (col == 2'd0) ? line[2] : (col == 2'd1) ? line[1] : (col == 2'd2) ? line[0] : 1'b0;
endmodule
