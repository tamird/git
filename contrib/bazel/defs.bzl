_GIT_BASE_COPTS = [
    "-g",
    "-O2",
    "-Wall",
    "-DUSE_CURL_FOR_IMAP_SEND",
    "-DSUPPORTS_SIMPLE_IPC",
    "-DUSE_LIBPCRE2",
    "-DSHA1_DC",
    "-DSHA1DC_NO_STANDARD_INCLUDES",
    "-DSHA1DC_INIT_SAFE_HASH_DEFAULT=0",
    '-DSHA1DC_CUSTOM_INCLUDE_SHA1_C=\\"git-compat-util.h\\"',
    '-DSHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\\"git-compat-util.h\\"',
    "-DSHA256_BLK",
    '-DSHELL_PATH=\\"/bin/sh\\"',
    '-DGIT_HTML_PATH=\\"share/doc/git-doc\\"',
    '-DGIT_MAN_PATH=\\"share/man\\"',
    '-DGIT_INFO_PATH=\\"share/info\\"',
    '-DGIT_EXEC_PATH=\\"libexec/git-core\\"',
    '-DGIT_LOCALE_PATH=\\"share/locale\\"',
    '-DBINDIR=\\"bin\\"',
    '-DFALLBACK_RUNTIME_PREFIX=\\"\\"',
    '-DDEFAULT_GIT_TEMPLATE_DIR=\\"share/git-core/templates\\"',
    '-DETC_GITCONFIG=\\"etc/gitconfig\\"',
    '-DETC_GITATTRIBUTES=\\"etc/gitattributes\\"',
    "-DPAGER_ENV='\"LESS=FRX LV=-c\"'",
    "-DNO_GETTEXT",
    "-DRUNTIME_PREFIX",
    "-DWITH_RUST",
]

_GIT_CPU_DEFINES = select({
    "@platforms//cpu:aarch64": ['-DGIT_HOST_CPU=\\"aarch64\\"'],
    "@platforms//cpu:arm64": ['-DGIT_HOST_CPU=\\"aarch64\\"'],
    "@platforms//cpu:x86_64": ['-DGIT_HOST_CPU=\\"x86_64\\"'],
    "//conditions:default": ['-DGIT_HOST_CPU=\\"unknown\\"'],
})

_GIT_MACOS_ICONV_COPTS = [
    # v2.53.0: Work around broken system iconv on newer macOS versions.
    "-DICONV_RESTART_RESET",
]

_GIT_MACOS_ICONV_LINKOPTS = [
    "-liconv",
]

_GIT_OS_DEFINES = select({
    "@platforms//os:linux": [
        "-DHAVE_ALLOCA_H",
        "-DHAVE_PATHS_H",
        "-DHAVE_DEV_TTY",
        "-DHAVE_CLOCK_GETTIME",
        "-DHAVE_CLOCK_MONOTONIC",
        "-DHAVE_SYNC_FILE_RANGE",
        "-DHAVE_SYSINFO",
        "-DHAVE_GETDELIM",
        "-DHAVE_GETRANDOM",
        "-DFREAD_READS_DIRECTORIES",
        "-DNO_STRLCPY",
        "-DNO_ICONV",
        '-DPROCFS_EXECUTABLE_PATH=\\"/proc/self/exe\\"',
        "-DHAVE_FSMONITOR_DAEMON_BACKEND",
        "-DHAVE_FSMONITOR_OS_SETTINGS",
    ],
    "@platforms//os:macos": [
        "-DHAVE_PATHS_H",
        "-DHAVE_DEV_TTY",
        "-DHAVE_GETDELIM",
        "-DFREAD_READS_DIRECTORIES",
        "-DNO_MEMMEM",
        "-DUSE_ST_TIMESPEC",
        "-DPRECOMPOSE_UNICODE",
        "-DPROTECT_HFS_DEFAULT=1",
        "-DHAVE_BSD_SYSCTL",
        "-DHAVE_NS_GET_EXECUTABLE_PATH",
        "-DUSE_ENHANCED_BASIC_REGULAR_EXPRESSIONS",
        "-DHAVE_ARC4RANDOM",
        # fsmonitor
        "-DHAVE_FSMONITOR_DAEMON_BACKEND",
        "-DHAVE_FSMONITOR_OS_SETTINGS",
    ] + _GIT_MACOS_ICONV_COPTS,
    "@platforms//os:windows": [
        # fsmonitor
        "-DHAVE_FSMONITOR_DAEMON_BACKEND",
        "-DHAVE_FSMONITOR_OS_SETTINGS",
        "-DNO_ICONV",
    ],
    "//conditions:default": [],
})

GIT_COPTS = _GIT_BASE_COPTS + _GIT_CPU_DEFINES + _GIT_OS_DEFINES

GIT_LINKOPTS = ["-lpthread"] + select({
    "@platforms//os:macos": [
        "-framework",
        "CoreServices",
    ] + _GIT_MACOS_ICONV_LINKOPTS,
    "//conditions:default": [],
})

def _git_version_template_impl(ctx):
    inputs = [ctx.file.template]
    arguments = [
        ctx.executable.generator.path,
        ctx.file.template.path,
        ctx.outputs.out.path,
    ]

    if ctx.attr.stamp:
        inputs.append(ctx.info_file)
        arguments.append(ctx.info_file.path)

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [ctx.outputs.out],
        tools = [ctx.executable.generator],
        arguments = arguments,
        command = """
set -eu

GIT_VERSION=2.55.0
GIT_BUILT_FROM_COMMIT=unknown
GIT_DATE=1970-01-01
GIT_USER_AGENT=

if [ "$#" -eq 4 ]; then
    while IFS=' ' read -r key value; do
        case "$key" in
            STABLE_GIT_VERSION) GIT_VERSION="$value" ;;
            STABLE_GIT_BUILT_FROM_COMMIT) GIT_BUILT_FROM_COMMIT="$value" ;;
            STABLE_GIT_DATE) GIT_DATE="$value" ;;
            STABLE_GIT_USER_AGENT) GIT_USER_AGENT="$value" ;;
        esac
    done < "$4"
fi

export GIT_VERSION GIT_BUILT_FROM_COMMIT GIT_DATE GIT_USER_AGENT
"$1" "$PWD" "$2" "$3"
""",
        mnemonic = "GitVersionTemplate",
    )

    return [DefaultInfo(files = depset([ctx.outputs.out]))]

git_version_template = rule(
    implementation = _git_version_template_impl,
    attrs = {
        "generator": attr.label(
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
        "out": attr.output(mandatory = True),
        "stamp": attr.bool(default = False),
        "template": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)

def _frankengit_release_transition_impl(_settings, attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": str(attr.platform),
        "//command_line_option:stamp": True,
    }

_frankengit_release_transition = transition(
    implementation = _frankengit_release_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        "//command_line_option:stamp",
    ],
)

def _frankengit_release_impl(ctx):
    runtime = ctx.attr.runtime[0][DefaultInfo]
    artifacts = runtime.files.to_list()
    outputs = []
    arguments = []

    for artifact in artifacts:
        output = ctx.actions.declare_file(ctx.label.name + "/" + artifact.basename)
        outputs.append(output)
        arguments.extend([artifact.path, output.path])

    ctx.actions.run_shell(
        inputs = artifacts,
        outputs = outputs,
        arguments = arguments,
        command = """
set -eu
while [ "$#" -gt 0 ]; do
    cp -L "$1" "$2"
    chmod +x "$2"
    test -x "$2"
    shift 2
done
""",
        mnemonic = "GitReleaseRuntime",
    )

    return [DefaultInfo(files = depset(outputs))]

frankengit_release = rule(
    implementation = _frankengit_release_impl,
    attrs = {
        "platform": attr.label(mandatory = True),
        "runtime": attr.label(
            cfg = _frankengit_release_transition,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
    },
)
