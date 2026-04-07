const std = @import("std");

pub fn build(b: *std.Build) void {
    const native_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Native build
    const native_exe = b.addExecutable(.{
        .name = "status-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = native_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(native_exe);

    // Run step (for development)
    const run_cmd = b.addRunArtifact(native_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the status agent");
    run_step.dependOn(&run_cmd.step);

    // Cross-compile: Linux x86_64
    const linux_exe = b.addExecutable(.{
        .name = "status-agent-linux-x86_64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
            }),
            .optimize = .ReleaseSafe,
        }),
    });
    const install_linux = b.addInstallArtifact(linux_exe, .{});
    const linux_step = b.step("linux", "Build for Linux x86_64");
    linux_step.dependOn(&install_linux.step);

    // Cross-compile: Windows x86_64
    const windows_exe = b.addExecutable(.{
        .name = "status-agent-windows-x86_64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
            }),
            .optimize = .ReleaseSafe,
        }),
    });
    const install_windows = b.addInstallArtifact(windows_exe, .{});
    const windows_step = b.step("windows", "Build for Windows x86_64");
    windows_step.dependOn(&install_windows.step);

    // Build all targets
    const all_step = b.step("all", "Build for all platforms");
    all_step.dependOn(&install_linux.step);
    all_step.dependOn(&install_windows.step);
}
