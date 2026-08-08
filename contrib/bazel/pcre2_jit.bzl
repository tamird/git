"""Build Git's PCRE2 with JIT without changing the shared dependency."""

_NEXT_TARGET = """
cc_library(
    name = "pcre2-posix","""

_TEXTUAL_HEADERS = "    textual_hdrs = [\n"

_JIT_TEXTUAL_HEADERS = """    textual_hdrs = glob([
        "src/pcre2_jit*.h",
        "deps/sljit/sljit_src/**/*.c",
        "deps/sljit/sljit_src/**/*.h",
    ]) + [
"""

_LOCAL_DEFINES = """        "SUPPORT_UNICODE",
    ],
    includes = ["src"],
"""

_JIT_LOCAL_DEFINES = """        "SUPPORT_UNICODE",
    ] + select({
        "@platforms//cpu:aarch64": ["SUPPORT_JIT"],
        "@platforms//cpu:x86_64": ["SUPPORT_JIT"],
        "//conditions:default": [],
    }) + select({
        "@platforms//os:linux": ["SLJIT_WX_EXECUTABLE_ALLOCATOR=1"],
        "//conditions:default": [],
    }),
    includes = ["src"],
"""

def _replace_once(contents, previous, replacement, description):
    if contents.count(previous) != 1:
        fail("unexpected PCRE2 BUILD layout for " + description)
    return contents.replace(previous, replacement)

def _pcre2_jit_repository_impl(repository_ctx):
    upstream_build = repository_ctx.path(repository_ctx.attr._upstream_build)
    contents = repository_ctx.read(upstream_build)

    if contents.count(_NEXT_TARGET) != 1:
        fail("unexpected PCRE2 BUILD layout after its library target")
    contents = contents.split(_NEXT_TARGET)[0]

    contents = _replace_once(
        contents,
        _TEXTUAL_HEADERS,
        _JIT_TEXTUAL_HEADERS,
        "SLJIT textual headers",
    )
    contents = _replace_once(
        contents,
        _LOCAL_DEFINES,
        _JIT_LOCAL_DEFINES,
        "JIT and executable-memory settings",
    )

    for directory in ["src", "deps"]:
        repository_ctx.symlink(upstream_build.dirname.get_child(directory), directory)

    repository_ctx.file("BUILD.bazel", contents + "\n", executable = False)

pcre2_jit_repository = repository_rule(
    implementation = _pcre2_jit_repository_impl,
    attrs = {
        "_upstream_build": attr.label(default = Label("@pcre2//:BUILD.bazel")),
    },
)
