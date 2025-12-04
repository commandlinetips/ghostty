//! Benchmark for BiDi (Bidirectional) text rendering performance.
//!
//! This benchmark measures the performance impact of Arabic/RTL text support
//! on both Latin (LTR) and Arabic (RTL) text rendering. The goal is to
//! demonstrate that LTR text has zero overhead from the BiDi implementation.
//!
//! Usage:
//!   zig build -Demit-bench
//!   ./zig-out/bin/ghostty-bench bidi-text --mode=latin
//!   ./zig-out/bin/ghostty-bench bidi-text --mode=arabic
//!   ./zig-out/bin/ghostty-bench bidi-text --mode=mixed

const BiDiText = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const terminalpkg = @import("../terminal/main.zig");
const BiDi = @import("../text/BiDi.zig");

/// The mode of text to benchmark
mode: Mode,
alloc: Allocator,
terminal: terminalpkg.Terminal,

pub const Mode = enum {
    /// Pure Latin text (should have zero BiDi overhead)
    latin,
    /// Pure Arabic text (BiDi processing active)
    arabic,
    /// Mixed Latin + Arabic text
    mixed,
};

pub const Options = struct {
    mode: Mode = .latin,
};

pub fn create(alloc: Allocator, opts: Options) !*BiDiText {
    const ptr = try alloc.create(BiDiText);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .mode = opts.mode,
        .alloc = alloc,
        .terminal = try terminalpkg.Terminal.init(alloc, .{
            .cols = 80,
            .rows = 24,
        }),
    };

    return ptr;
}

pub fn destroy(self: *BiDiText, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *BiDiText) Benchmark {
    return Benchmark.init(self, .{
        .setupFn = setup,
        .teardownFn = teardown,
        .stepFn = step,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BiDiText = @ptrCast(@alignCast(ptr));

    // Always reset terminal state
    self.terminal.fullReset();

    // Write test text to the terminal based on mode
    const text = switch (self.mode) {
        .latin => "The quick brown fox jumps over the lazy dog. Hello World!",
        .arabic => "مرحبا بك في تطبيق غوستي البرمجة بلغة زيج سريعة وآمنة",
        .mixed => "Hello مرحبا World العالم Testing الاختبار",
    };

    // Write text to terminal
    self.terminal.printString(text) catch {
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    _ = ptr;
    // Nothing to do here - cleanup happens in destroy()
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BiDiText = @ptrCast(@alignCast(ptr));

    // Simulate text rendering operations that would trigger BiDi
    const screen = self.terminal.screens.active;
    const pin = screen.pages.pin(.{ .viewport = .{} }) orelse return;

    // Get the row cells (this is what the renderer would do)
    const rac = pin.rowAndCell();
    const pg = pin.node.data;
    const row = rac.row.*;
    const base: [*]u8 = @ptrCast(pg.memory.ptr);
    const cells = row.cells.ptr(base)[0..pg.size.cols];

    // Simulate BiDi processing path (what happens in renderer)
    if (cells.len > 0) {
        // Check for complex scripts (early exit optimization)
        var has_complex = false;
        for (cells) |cell| {
            if (cell.hasText()) {
                const cp = cell.codepoint();
                const script = BiDi.detectScript(cp);
                if (BiDi.isComplexScript(script)) {
                    has_complex = true;
                    break;
                }
            }
        }

        // This is the key: Latin text exits here with zero overhead
        if (!has_complex) return;

        // For Arabic text, perform BiDi analysis
        var codepoints = std.ArrayList(u32).initCapacity(self.alloc, cells.len) catch return error.BenchmarkFailed;
        defer codepoints.deinit(self.alloc);

        for (cells) |cell| {
            const cp = if (cell.hasText()) cell.codepoint() else 0x20;
            codepoints.appendAssumeCapacity(cp);
        }

        // BiDi analysis (only happens for Arabic text)
        var analysis = BiDi.analyzeBidiCodepoints(self.alloc, codepoints.items) catch return error.BenchmarkFailed;
        defer analysis.deinit();

        // Visual reordering
        const logical_to_visual = BiDi.reorderVisualCodepoints(
            self.alloc,
            codepoints.items,
            &analysis,
        ) catch return error.BenchmarkFailed;
        defer self.alloc.free(logical_to_visual);
    }
}
