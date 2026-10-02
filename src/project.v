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
 *
 * Levels: every 10 points the game gets harder.
 *   0-9: wide gaps (128 px)   10-19: 112 px gaps   20-29: faster pipes, night
 *   30+: 96 px gaps, fast, night
 *
 * The renderer is written as if/else chains of small functions, so a cycle-based
 * simulator (like vga-playground.com) only evaluates the layer that is visible at
 * each pixel. The hardware is the same as with plain ?: expressions.
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
  reg [5:0] color;  // {R, G, B}, 2 bits each, from the renderer below

  assign uo_out = {hsync, color[0], color[2], color[4], vsync, color[1], color[3], color[5]};

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
  reg [7:0] gap_a, gap_b;      // gap top line
  reg vis_a;                   // pipe A is in play (pipe B always is while playing)
  reg passed_a;                // the bird already flew through pipe A
  reg [3:0] score_lo, score_hi, best_lo, best_hi;
  reg new_record;              // the last game beat the best score
  reg [8:0] bg_scroll;         // frame counter, also the background parallax scroll
  reg [9:0] lfsr;
  reg [4:0] dead_timer;
  reg hit;
  reg sw_prev, btn_prev;

  wire [8:0] bird_y = bird_yf[10:2];
  wire fast = (score_hi >= 4'd2);   // 20+ points: pipes move 4 px per frame
  wire night = (state != S_READY) && fast;
  // Gap size: 128 px, then 112 px from 10 points and 96 px from 30 points
  wire [1:0] gsize = (score_hi == 4'd0) ? 2'd0 : (score_hi < 4'd3) ? 2'd1 : 2'd2;

  // Sound
  localparam [1:0] SND_FLAP = 2'd1, SND_SCORE = 2'd2, SND_HIT = 2'd3;
  reg [1:0] snd_type;
  reg [4:0] snd_timer;
  reg sound;

  // Per-frame temporaries (only evaluated on frame_tick)
  /* verilator lint_off BLKSEQ */
  reg [7:0] new_gap, next_gap;
  reg a_ahead, scores, wrap, auto_flap, press, y_floor, new_best, level_up;
  reg signed [12:0] y_next;
  reg signed [6:0] vel_fall;
  reg [3:0] score_lo_inc, score_hi_inc;
  reg [5:0] frame;
  reg [8:0] phase_next;

  wire hit_px;  // from the renderer: a bird pixel on top of a pipe pixel

  always @(posedge clk) begin
    if (~rst_n) begin
      state      <= S_READY;
      bird_yf    <= 11'd800;
      vel        <= 7'sd0;
      phase      <= 9'd351;
      gap_a      <= 8'd120;
      gap_b      <= 8'd160;
      vis_a      <= 1'b0;
      passed_a   <= 1'b0;
      score_lo   <= 4'd0;
      score_hi   <= 4'd0;
      best_lo    <= 4'd0;
      best_hi    <= 4'd0;
      new_record <= 1'b0;
      bg_scroll  <= 9'd0;
      lfsr       <= 10'h2E1;
      dead_timer <= 5'd0;
      hit        <= 1'b0;
      sw_prev    <= 1'b0;
      btn_prev   <= 1'b0;
      snd_type   <= 2'd0;
      snd_timer  <= 5'd0;
    end else begin
      // Free-running LFSR: the player's timing makes the pipes random
      lfsr <= {lfsr[8:0], lfsr[9] ^ lfsr[6]};

      // Collision: a bird pixel drawn on top of a pipe pixel
      if (hit_px) hit <= 1'b1;

      if (frame_tick) begin
        frame    = bg_scroll[5:0];
        // New gap: 48 + 3 * random(0..63)
        new_gap  = 8'd48 + {2'b00, lfsr[5:0]} + {1'b0, lfsr[5:0], 1'b0};
        // Pipe A passes the bird when its right edge (phase - 4 in screen x + 64) is left of x = 160
        a_ahead  = vis_a & ~passed_a;
        scores   = a_ahead & (phase < 9'd164);
        // Pipes move 3 px per frame (4 px when fast)
        phase_next = phase - 9'd3 - {8'd0, fast};
        wrap     = (phase < 9'd3) || (fast && phase == 9'd3);
        // Autopilot: flap when the bird drops 68 px below the top of the next gap
        next_gap = a_ahead ? gap_a : gap_b;
        auto_flap = ui_in[1] & ~vel[6] & (bird_y >= {1'b0, next_gap} + 9'd68);
        press    = (ui_in[0] ^ sw_prev) | (ui_in[2] & ~btn_prev);
        // Physics
        y_next   = $signed({2'b00, bird_yf}) + {{6{vel[6]}}, vel};
        y_floor  = (y_next >= $signed({2'b00, BIRD_YMAX}));
        vel_fall = (vel < MAX_VEL) ? vel + 7'sd1 : vel;
        // Score with BCD increment (saturates at 99)
        score_lo_inc = (score_lo == 4'd9) ? ((score_hi == 4'd9) ? 4'd9 : 4'd0) : score_lo + 4'd1;
        score_hi_inc = (score_lo == 4'd9 && score_hi != 4'd9) ? score_hi + 4'd1 : score_hi;
        level_up = (score_lo == 4'd9) && (score_hi != 4'd9);
        new_best = {score_hi, score_lo} > {best_hi, best_lo};

        hit      <= 1'b0;
        sw_prev  <= ui_in[0];
        btn_prev <= ui_in[2];
        if (snd_timer != 5'd0) snd_timer <= snd_timer - 5'd1;
        if (state != S_DEAD) bg_scroll <= bg_scroll + 9'd1;

        case (state)
          S_READY: begin
            // Bird bobs up and down while waiting; the ground keeps scrolling
            bird_yf <= {2'b00, 9'd200 + {5'd0, frame[5] ? frame[4:1] : ~frame[4:1]}} << 2;
            phase <= wrap ? phase_next + 9'd352 : phase_next;
            if (press || (ui_in[1] && frame == 6'd0)) begin
              state      <= S_PLAY;
              vel        <= FLAP_VEL;
              phase      <= 9'd351;   // pipe B enters at the right edge, pipe A is not used yet
              gap_b      <= new_gap;
              vis_a      <= 1'b0;
              passed_a   <= 1'b0;
              score_lo   <= 4'd0;
              score_hi   <= 4'd0;
              new_record <= 1'b0;
              snd_type   <= SND_FLAP;
              snd_timer  <= 5'd8;
            end
          end

          S_PLAY: begin
            // Pipes scroll left; when pipe A leaves the screen, B becomes A and a new B appears
            if (wrap) begin
              phase    <= phase_next + 9'd352;
              gap_a    <= gap_b;
              gap_b    <= new_gap;
              vis_a    <= 1'b1;
              passed_a <= 1'b0;
            end else begin
              phase <= phase_next;
            end

            if (scores) begin
              passed_a  <= 1'b1;
              score_lo  <= score_lo_inc;
              score_hi  <= score_hi_inc;
              snd_type  <= SND_SCORE;
              snd_timer <= level_up ? 5'd31 : 5'd12;
            end

            // Bird physics
            if (press || auto_flap) begin
              vel <= FLAP_VEL;
              if (!scores && !(snd_type == SND_SCORE && snd_timer[4])) begin  // keep the level-up tune
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
              dead_timer <= 5'd0;
              vel        <= 7'sd0;
              snd_type   <= SND_HIT;
              snd_timer  <= 5'd24;
              if (new_best) begin
                best_lo    <= score_lo;
                best_hi    <= score_hi;
                new_record <= 1'b1;
              end
            end
          end

          default: begin  // S_DEAD: the bird drops to the ground
            if (dead_timer != 5'd31) dead_timer <= dead_timer + 5'd1;
            vel <= vel_fall;
            if (y_floor) bird_yf <= BIRD_YMAX;
            else if (y_next >= 0) bird_yf <= y_next[10:0];
            if (dead_timer == 5'd31 && (press || ui_in[1])) begin
              state <= S_READY;
              vel   <= 7'sd0;
            end
          end
        endcase
      end
    end
  end

  // Sound generator, updated once per scanline. The scanline counter is a free clock
  // divider: pix_y[k] is a square wave of 31469 / 2^(k+1) Hz. Flap: 492 Hz -> 983 Hz
  // chirp. Score: 983 Hz -> 1967 Hz. Level up: three-note arpeggio. Crash: noise.
  always @(posedge clk) begin
    if (~rst_n) sound <= 1'b0;
    else if (line_tick) begin
      if (snd_timer == 5'd0) sound <= 1'b0;
      else begin
        case (snd_type)
          SND_HIT:  sound <= lfsr[0];
          SND_FLAP: sound <= snd_timer[2] ? pix_y[5] : pix_y[4];
          default:  sound <= snd_timer[4] ? pix_y[5] : snd_timer[3] ? pix_y[4] : pix_y[3];
        endcase
      end
    end
  end
  assign uio_out = {sound, 7'b0};
  assign uio_oe  = 8'b1000_0000;
  /* verilator lint_on BLKSEQ */

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------
  wire flash = (state == S_DEAD) && (dead_timer < 5'd4);
  wire show_go = (state == S_DEAD) && (dead_timer >= 5'd12);       // "GAME OVER"
  // The top number is the score; on the title screen it is the best score
  // (orange, blinking after a new record)
  wire title = (state == S_READY);
  wire show_num = !title || !new_record || bg_scroll[4];
  wire [3:0] num_hi = title ? best_hi : score_hi;
  wire [3:0] num_lo = title ? best_lo : score_lo;

  reg [6:0] b_px, p_px, t_px;  // {opaque, color}
  always @(*) begin
    color = 6'd0;
    b_px  = 7'd0;
    p_px  = 7'd0;
    t_px  = 7'd0;
    if (video_active) begin
      // Bird: 32x24 box at x = 160..191
      if (pix_x[9:5] == 5'd5) b_px = bird_px(pix_x[4:1], pix_y, bird_y);
      // Pipes are never drawn on the title screen or over the ground
      if (!title && pix_y < GROUND_Y)
        p_px = pipe_px(pix_x, pix_y, phase, gap_a, gap_b, gsize, vis_a);
      if (flash) begin
        color = 6'b11_11_11;
      end else begin
        t_px = text_px(pix_x, pix_y, title, num_hi, num_lo, show_num, show_go);
        if (t_px[6]) color = t_px[5:0];
        else if (b_px[6]) color = b_px[5:0];
        else if (p_px[6]) color = p_px[5:0];
        else if (pix_y >= GROUND_Y)
          // the ground moves with the pipes (and slowly on the title screen)
          color = ground_px(pix_x[4:0], pix_y[4:0], pix_y[9:4] == 6'd26, -phase[4:0]);
        else color = bg_px(pix_x[8:0], pix_y, bg_scroll, night, bg_scroll[4]);
      end
    end
  end
  assign hit_px = b_px[6] & p_px[6];

  // ---------------------------------------------------------------------------
  // Bird sprite: 16x12 pixels drawn at 2x (32x24). Returns {opaque, color}.
  // ---------------------------------------------------------------------------
  function [6:0] bird_px(input [3:0] col, input [9:0] y, input [8:0] by);
    reg [9:0] bdy;
    reg [3:0] row;
    reg [1:0] idx;
    begin
      bird_px = 7'd0;
      bdy = y - {1'b0, by};
      if (bdy < 10'd24) begin
        row = bdy[4:1];
        idx = bird_sprite(row, col);
        if (idx == 2'd1) bird_px = {1'b1, 6'b00_00_00};
        else if (idx == 2'd2) bird_px = {1'b1, 6'b11_11_00};
        else if (idx == 2'd3) bird_px = {1'b1, ((row >= 4'd6) && (col >= 4'd10)) ? 6'b11_01_00 : 6'b11_11_11};
      end
    end
  endfunction

  // 0 = transparent, 1 = black, 2 = yellow, 3 = white (orange on the beak)
  function [1:0] bird_sprite(input [3:0] row, input [3:0] col);
    reg [31:0] bits;
    begin
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
      bird_sprite = bits[{~col, 1'b0} +: 2];  // col 0 is the most significant pair
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Pipes: they are 352 px apart, so at most one of them is under the beam.
  // Each one is 60 px wide; the gap is 128, 112 or 96 px. Returns {opaque, color}.
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNUSED */  // db[0] is not needed
  function [6:0] pipe_px(input [9:0] x, input [9:0] y, input [8:0] ph, input [7:0] ga, input [7:0] gb,
                         input [1:0] gs, input va);
    reg [10:0] lxa, lxb;
    reg [5:0] lx;
    reg [7:0] gap;
    reg [9:0] dt, db;
    reg top_cap, bot_cap, edge_px, near;
    begin
      pipe_px = 7'd0;
      lxa = {1'b0, x} + 11'd64 - {2'b00, ph};
      lxb = lxa - 11'd352;
      near = 1'b0;
      lx = 6'd0;
      gap = 8'd0;
      if (va && lxa[10:6] == 5'd0) begin
        lx = lxa[5:0];
        gap = ga;
        near = 1'b1;
      end else if (lxb[10:6] == 5'd0) begin
        lx = lxb[5:0];
        gap = gb;
        near = 1'b1;
      end
      if (near && lx[5:2] != 4'd15) begin  // 0 <= lx < 60
        dt = y - {2'b00, gap};                           // y - gap top
        db = dt - 10'd128 + {4'd0, gs, 4'd0};           // y - gap bottom
        top_cap = dt[9] && (dt[8:5] == 4'b1111) && (dt[4:3] != 2'b00);  // -24 <= dt < 0
        bot_cap = !db[9] && (db[9:5] == 5'd0) && (db[4:3] != 2'b11);    // 0 <= db < 24
        if (top_cap || bot_cap) begin
          // Cap: 60 px wide, 2 px black outline
          edge_px = (lx[5:1] == 5'd0) || (lx[5:1] == 5'd29) ||
                    (top_cap ? (dt[4:1] == 4'd4 || dt[4:1] == 4'd15) : (db[4:1] == 4'd0 || db[4:1] == 4'd11));
          pipe_px = {1'b1, pipe_shade(lx[5:3], edge_px)};
        end else if ((dt[9] || !db[9]) && lx >= 6'd4 && lx < 6'd56) begin
          // Body: 4 px narrower than the cap on each side
          pipe_px = {1'b1, pipe_shade(lx[5:3], lx[5:1] == 5'd2 || lx[5:1] == 5'd27)};
        end
      end
    end
  endfunction

  /* verilator lint_on UNUSED */

  // Pipe colors by 8 px band: black outline, light, highlight, green, dark green
  function [5:0] pipe_shade(input [2:0] band, input edge_px);
    begin
      if (edge_px) pipe_shade = 6'b00_00_00;
      else if (band == 3'd0) pipe_shade = 6'b01_11_01;
      else if (band == 3'd1) pipe_shade = 6'b10_11_10;
      else if (band < 3'd5) pipe_shade = 6'b00_10_00;
      else pipe_shade = 6'b00_01_00;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Text, all with one 3x5 font. Positions are aligned so that glyph
  // coordinates are plain bit slices. Returns {opaque, color}.
  //   Number:    8x, top of the screen: the score (white) or, on the title
  //              screen, the best score (orange)
  //   Title:    16x, "LUIS" on the title screen
  //   GAME OVER: 4x, after a crash
  // ---------------------------------------------------------------------------
  function [6:0] text_px(input [9:0] x, input [9:0] y, input ttl,
                         input [3:0] n_hi, input [3:0] n_lo, input num, input go);
    reg [4:0] glyph;
    reg [2:0] g_row;
    reg [1:0] g_col;
    reg [5:0] tcol;
    reg in_box;
    begin
      text_px = 7'd0;
      in_box = 1'b0;
      glyph = 5'd31;
      g_row = 3'd0;
      g_col = 2'd0;
      tcol = 6'b11_11_11;
      if (y < 10'd64) begin
        // Number: x 288..343 (2 slots of 32 px), y 24..63
        if (num && y >= 10'd24 && x >= 10'd288 && x < 10'd344 && x[4:3] != 2'd3 &&
            (~x[5] || n_hi != 4'd0)) begin
          in_box = 1'b1;
          glyph = {1'b0, x[5] ? n_hi : n_lo};
          g_row = y[5:3] - 3'd3;
          g_col = x[4:3];
          if (ttl) tcol = 6'b11_01_00;
        end
      end else if (y < 10'd176) begin
        if (ttl) begin
          // Title: x 192..431 (4 slots of 64 px, letters 48 px wide), y 96..175
          if (y >= 10'd96 && x >= 10'd192 && x < 10'd432 && x[5:4] != 2'd3) begin
            in_box = 1'b1;
            case (x[7:6])
              2'd3: glyph = 5'd10;  // L (x 192..255)
              2'd0: glyph = 5'd11;  // U (x 256..319)
              2'd1: glyph = 5'd12;  // I (x 320..383)
              default: glyph = 5'd5;  // S (x 384..447)
            endcase
            g_row = y[6:4] - 3'd6;
            g_col = x[5:4];
            tcol = 6'b11_10_00;
          end
        end else if (go && y >= 10'd128 && y < 10'd148 && x >= 10'd256 && x < 10'd400) begin
          // GAME OVER: x 256..399 (9 slots of 16 px), y 128..147
          in_box = 1'b1;
          case (x[8:4])
            5'd16: glyph = 5'd13;  // G
            5'd17: glyph = 5'd14;  // A
            5'd18: glyph = 5'd15;  // M
            5'd19: glyph = 5'd16;  // E
            5'd21: glyph = 5'd0;   // O
            5'd22: glyph = 5'd17;  // V
            5'd23: glyph = 5'd16;  // E
            5'd24: glyph = 5'd18;  // R
            default: glyph = 5'd31;
          endcase
          g_row = y[4:2];
          g_col = x[3:2];
          tcol = 6'b11_00_00;
        end
      end
      if (in_box && font_3x5(glyph, g_row, g_col)) text_px = {1'b1, tcol};
    end
  endfunction

  // 3x5 font: digits 0-9, L, U, I, G, A, M, E, V, R
  function font_3x5(input [4:0] glyph, input [2:0] row, input [1:0] col);
    reg [14:0] g;
    reg [2:0] line;
    begin
      case (glyph)
        5'd0:  g = 15'b111_101_101_101_111;
        5'd1:  g = 15'b010_110_010_010_111;
        5'd2:  g = 15'b111_001_111_100_111;
        5'd3:  g = 15'b111_001_111_001_111;
        5'd4:  g = 15'b101_101_111_001_001;
        5'd5:  g = 15'b111_100_111_001_111;
        5'd6:  g = 15'b111_100_111_101_111;
        5'd7:  g = 15'b111_001_001_001_001;
        5'd8:  g = 15'b111_101_111_101_111;
        5'd9:  g = 15'b111_101_111_001_111;
        5'd10: g = 15'b100_100_100_100_111;  // L
        5'd11: g = 15'b101_101_101_101_111;  // U
        5'd12: g = 15'b111_010_010_010_111;  // I
        5'd13: g = 15'b111_100_101_101_111;  // G
        5'd14: g = 15'b111_101_111_101_101;  // A
        5'd15: g = 15'b101_111_111_101_101;  // M
        5'd16: g = 15'b111_100_111_100_111;  // E
        5'd17: g = 15'b101_101_101_101_010;  // V
        5'd18: g = 15'b110_101_110_101_101;  // R
        default: g = 15'd0;
      endcase
      case (row)
        3'd0: line = g[14:12];
        3'd1: line = g[11:9];
        3'd2: line = g[8:6];
        3'd3: line = g[5:3];
        3'd4: line = g[2:0];
        default: line = 3'd0;
      endcase
      font_3x5 = (col == 2'd3) ? 1'b0 : line[2 - col];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Ground: lines 416..431 are a black edge, striped grass and dark grass,
  // then the dirt has diagonal stripes. ofs = scroll offset.
  // ---------------------------------------------------------------------------
  function [5:0] ground_px(input [4:0] x, input [4:0] y, input grass, input [4:0] ofs);
    reg [4:0] gx;
    begin
      gx = x + ofs;
      if (grass) begin
        if (y[3:2] == 2'd0) ground_px = 6'b00_00_00;
        else if (y[3:2] == 2'd3) ground_px = 6'b01_10_00;
        else ground_px = gx[3] ? 6'b01_11_00 : 6'b10_11_00;
      end else begin
        ground_px = ((gx + y) >= 5'd16) ? 6'b11_10_01 : 6'b10_10_01;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Background: sky gradient (or a starry night sky), clouds, city skyline and
  // bushes, scrolling slower than the pipes (parallax). Checked from the top down.
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNUSED */  // bgx[0] is not needed
  function [5:0] bg_px(input [8:0] x, input [9:0] y, input [8:0] scr, input nt, input twinkle);
    reg [8:0] bgx;
    reg [3:0] k;
    reg [2:0] h;
    reg dither, in_city, in_bush;
    begin
      dither = x[0] ^ y[0];
      if (y < 10'd304) begin
        if (nt) begin
          // Night: dark sky with stars (2x2 px, one possible star per 8x8 cell)
          if (y < 10'd256 && x[2:1] == 2'd1 && y[2:1] == 2'd2 &&
              ((x[7:3] ^ {y[5:3], y[7:6]}) == 5'b10110) && (twinkle || x[8]))
            bg_px = 6'b11_11_11;
          else if (y < 10'd240) bg_px = 6'b00_00_01;
          else bg_px = 6'b00_01_10;
        end else begin
          // Day: blue sky, lighter near the horizon
          if (y < 10'd240) bg_px = 6'b01_10_11;
          else bg_px = 6'b10_11_11;
        end
      end else begin
        bgx = x[8:0] + scr;
        if (y < 10'd320) begin
          // Clouds: a bumpy band behind the city
          if (y[3:0] >= (bgx[5] ? bgx[4:1] : ~bgx[4:1])) bg_px = nt ? 6'b01_01_10 : 6'b11_11_11;
          else bg_px = nt ? 6'b00_01_10 : 6'b10_11_11;
        end else begin
          // Bushes in front of the city, from y = 392 (dithered green)
          in_bush = (y[9:3] >= 7'd49);
          if (in_bush) begin
            if (nt) bg_px = dither ? 6'b00_01_00 : 6'b00_10_01;
            else bg_px = dither ? 6'b00_10_00 : 6'b01_11_01;
          end else begin
            // City skyline: 32 px wide buildings with lit windows. The roof of
            // building k is at row 41 + h(k) (rows of 8 px), h = a 3-bit hash of k.
            k = bgx[8:5];
            h = {k[0] ^ k[3], k[1] ^ k[2], k[3] ^ k[1] ^ k[0]};
            in_city = (y[9:3] >= 7'd41 + {4'd0, h}) && (bgx[4:1] != 4'd0);
            if (in_city) begin
              if ((bgx[2:1] == 2'b10) && (y[2:1] == 2'b01) && (bgx[4:3] != 2'b00))
                bg_px = nt ? 6'b11_11_00 : 6'b11_11_10;   // windows (lit at night)
              else bg_px = nt ? 6'b00_01_01 : 6'b01_10_10;
            end else begin
              bg_px = nt ? 6'b01_01_10 : 6'b11_11_11;     // clouds fill the rest from y = 320
            end
          end
        end
      end
    end
  endfunction
  /* verilator lint_on UNUSED */

endmodule
