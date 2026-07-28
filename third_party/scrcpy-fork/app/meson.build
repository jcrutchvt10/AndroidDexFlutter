project(
    'scrcpy',
    'c',
    # Keep in lockstep with server/build.gradle versionName (currently "4.1").
    # A client/server mismatch aborts every per-app viewport launch.
    version : '4.1',
    license : 'Apache-2.0',
    default_options : ['warning_level=2', 'buildtype=release'],
    meson_version : '>=0.61.0',
)
src = [
    'src/main.c',
    'src/adb/adb.c',
    'src/adb/adb_device.c',
    'src/adb/adb_parser.c',
    'src/adb/adb_tunnel.c',
    'src/audio_player.c',
    'src/audio_regulator.c',
    'src/cli.c',
    'src/clock.c',
    'src/compat.c',
    'src/control_msg.c',
    'src/controller.c',
    'src/decoder.c',
    'src/demuxer.c',
    'src/device_msg.c',
    'src/disconnect.c',
    'src/events.c',
    'src/icon.c',
    'src/file_pusher.c',
    'src/fps_counter.c',
    'src/frame_buffer.c',
    'src/input_manager.c',
    'src/keyboard_sdk.c',
    'src/mouse_capture.c',
    'src/mouse_sdk.c',
    'src/opengl.c',
    'src/options.c',
    'src/packet_merger.c',
    'src/receiver.c',
    'src/recorder.c',
    'src/scrcpy.c',
    'src/screen.c',
    'src/sdl_hints.c',
    'src/server.c',
    'src/texture.c',
    'src/version.c',
    'src/video_regulator.c',
    'src/hid/hid_gamepad.c',
    'src/hid/hid_keyboard.c',
    'src/hid/hid_mouse.c',
    'src/trait/frame_source.c',
    'src/trait/packet_source.c',
    'src/uhid/gamepad_uhid.c',
    'src/uhid/keyboard_uhid.c',
    'src/uhid/mouse_uhid.c',
    'src/uhid/uhid_output.c',
    'src/util/acksync.c',
    'src/util/audiobuf.c',
    'src/util/average.c',
    'src/util/env.c',
    'src/util/file.c',
    'src/util/intmap.c',
    'src/util/intr.c',
    'src/util/log.c',
    'src/util/memory.c',
    'src/util/net.c',
    'src/util/net_intr.c',
    'src/util/process.c',
    'src/util/process_intr.c',
    'src/util/rand.c',
    'src/util/sdl.c',
    'src/util/strbuf.c',
    'src/util/str.c',
    'src/util/term.c',
    'src/util/thread.c',
    'src/util/tick.c',
    'src/util/timeout.c',
]

feature_test_macros = [
    '-D_GNU_SOURCE',
    '-D_POSIX_C_SOURCE=200809L',
    '-D_XOPEN_SOURCE=700',
]

conf = configuration_data()

if host_machine.system() == 'windows'
    windows = import('windows')
    src += [
        'src/util/command.c',
        'src/sys/win/file.c',
        'src/sys/win/process.c',
        windows.compile_resources('scrcpy-windows.rc'),
    ]
    feature_test_macros += [
        '-D_WIN32_WINNT=0x0600',
        '-DWINVER=0x0600',
    ]
else
    src += [
        'src/sys/unix/file.c',
        'src/sys/unix/process.c',
    ]
    if host_machine.system() == 'darwin'
        feature_test_macros += '-D_DARWIN_C_SOURCE'
    endif
endif


add_project_arguments(feature_test_macros, language: 'c')



v4l2_support = get_option('v4l2') and host_machine.system() == 'linux'
if v4l2_support
    src += [ 'src/v4l2_sink.c' ]
endif

usb_support = get_option('usb')
if usb_support
    src += [
        'src/usb/aoa_hid.c',
        'src/usb/gamepad_aoa.c',
        'src/usb/keyboard_aoa.c',
        'src/usb/mouse_aoa.c',
        'src/usb/scrcpy_otg.c',
        'src/usb/usb.c',
    ]
endif

cc = meson.get_compiler('c')

# RewriteDEX fork: demote mingw-gcc's "unknown conversion type character 'z'"
# (C99 printf 'z' length modifier for size_t) from error to warning. SDL3's
# SDL_LogError in util/log.h is annotated as printf-format, so mingw gcc does
# strict format-string checking; mingw-w64's printf format table lacks 'z'
# even though the language is C11. Disabling just this one check keeps the
# real format errors (mismatched %d/%s etc.) as errors while letting %zu
# compile. MSVC's cl.exe does not understand -Wno-error= at all, so this
# flag is only added when the compiler is GCC or Clang.
if cc.get_id() == 'msvc'
    # MSVC needs explicit enabling of C11 atomics (VS 2022 17.5+)
    add_project_arguments('/experimental:c11atomics', language: 'c')
    # ssize_t (POSIX) is not available in MSVC's UCRT; define it via macro
    # using intptr_t (always available from MSVC's <stdint.h> or <basetsd.h>).
    add_project_arguments('-Dssize_t=intptr_t', language: 'c')
    # Provide getopt for MSVC (not available in Windows SDK)
    src += ['src/compat/getopt.c']
else
    # MinGW/GCC: use ANSI stdio so %zu (size_t) printf format is recognised
    add_project_arguments('-D__USE_MINGW_ANSI_STDIO=1', language: 'c')
    # Demote all format-string warnings so mingw's strict printf checking
    # (%zu, extra args to LOGE macros) does not break the build.
    add_project_arguments('-Wno-error=format', '-Wno-error=format-extra-args',
                          '-Wno-error=format-security', language: 'c')
endif

static = get_option('static')

dependencies = [
    dependency('libavformat', version: '>= 57.33', static: static),
    dependency('libavcodec', version: '>= 57.37', static: static),
    dependency('libavutil', static: static),
    dependency('libswresample', static: static),
    dependency('sdl3', version: '>= 3.2.0', static: static),
]

if v4l2_support
    dependencies += dependency('libavdevice', static: static)
endif

if usb_support
    dependencies += dependency('libusb-1.0', static: static)
endif

if host_machine.system() == 'windows'
    if cc.get_id() != 'msvc'
        # RewriteDEX fork: MinGW only. MSVC builds get vcruntime/msvcrt
        # from the Windows SDK automatically; mingw32.lib is not shipped.
        dependencies += cc.find_library('mingw32')
        # Allow multiple definitions in static link (Rust exception personality
        # symbols conflict across ffmpeg deps like librav1e.a / librsvg-2.a)
        add_project_link_arguments('-Wl,--allow-multiple-definition', language: 'c')
        # MinGW: ffmpeg shared libs need OpenMP (libsoxr uses omp_* locks)
        add_project_link_arguments('-fopenmp', language: 'c')
    endif
    dependencies += cc.find_library('ws2_32')
endif

check_functions = [
    'strdup',
    'asprintf',
    'vasprintf',
    'nrand48',
    'jrand48',
    'reallocarray',
]

foreach f : check_functions
  if cc.has_function(f)
    define = 'HAVE_' + f.underscorify().to_upper()
    conf.set(define, true)
  endif
endforeach

conf.set('HAVE_SOCK_CLOEXEC', host_machine.system() != 'windows' and
                              cc.has_header_symbol('sys/socket.h', 'SOCK_CLOEXEC'))

# the version, updated on release
conf.set_quoted('SCRCPY_VERSION', meson.project_version())

# the prefix used during configuration (meson --prefix=PREFIX)
conf.set_quoted('PREFIX', get_option('prefix'))

# build a "portable" version (with scrcpy-server accessible from the same
# directory as the executable)
conf.set('PORTABLE', get_option('portable'))

# the default client TCP port range for the "adb reverse" tunnel
# overridden by option --port
conf.set('DEFAULT_LOCAL_PORT_RANGE_FIRST', '27183')
conf.set('DEFAULT_LOCAL_PORT_RANGE_LAST', '27199')

# run a server debugger and wait for a client to be attached
conf.set('SERVER_DEBUGGER', get_option('server_debugger'))

# enable V4L2 support (linux only)
conf.set('HAVE_V4L2', v4l2_support)

# enable HID over AOA support (linux only)
conf.set('HAVE_USB', usb_support)

configure_file(configuration: conf, output: 'config.h')

src_dir = include_directories('src')

# For MSVC (no POSIX headers), include our compat getopt implementation
if cc.get_id() == 'msvc'
    compat_dir = include_directories('src/compat')
else
    compat_dir = include_directories('.')
endif

executable('scrcpy', src,
           dependencies: dependencies,
           include_directories: [src_dir, compat_dir],
           install: true,
           c_args: [])

# <https://mesonbuild.com/Builtin-options.html#directories>
datadir = get_option('datadir') # by default 'share'

install_man('scrcpy.1')
install_data('data/scrcpy.png',
             install_dir: datadir / 'icons/hicolor/256x256/apps')
install_data('data/disconnected.png',
             install_dir: datadir / 'icons/hicolor/256x256/apps')
install_data('data/zsh-completion/_scrcpy',
             install_dir: datadir / 'zsh/site-functions')
install_data('data/bash-completion/scrcpy',
             install_dir: datadir / 'bash-completion/completions')

# Desktop entry file for application launchers
if host_machine.system() == 'linux'
    # Install a launcher (ex: /usr/local/share/applications/scrcpy.desktop)
    install_data('data/scrcpy.desktop',
                 install_dir: datadir / 'applications')
    install_data('data/scrcpy-console.desktop',
                 install_dir: datadir / 'applications')
endif


### TESTS

# do not build tests in release (assertions would not be executed at all)
if get_option('buildtype') == 'debug'
    tests = [
        ['test_adb_parser', [
            'tests/test_adb_parser.c',
            'src/adb/adb_device.c',
            'src/adb/adb_parser.c',
            'src/util/str.c',
            'src/util/strbuf.c',
        ]],
        ['test_binary', [
            'tests/test_binary.c',
        ]],
        ['test_audiobuf', [
            'tests/test_audiobuf.c',
            'src/util/audiobuf.c',
            'src/util/memory.c',
        ]],
        ['test_cli', [
            'tests/test_cli.c',
            'src/cli.c',
            'src/options.c',
            'src/util/log.c',
            'src/util/net.c',
            'src/util/str.c',
            'src/util/strbuf.c',
            'src/util/term.c',
        ]],
        ['test_command_windows', [
          'tests/test_command_windows.c',
          'src/util/command.c',
          'src/util/str.c',
          'src/util/strbuf.c',
        ]],
        ['test_control_msg_serialize', [
            'tests/test_control_msg_serialize.c',
            'src/control_msg.c',
            'src/util/str.c',
            'src/util/strbuf.c',
        ]],
        ['test_device_msg_deserialize', [
            'tests/test_device_msg_deserialize.c',
            'src/device_msg.c',
        ]],
        ['test_orientation', [
            'tests/test_orientation.c',
            'src/options.c',
        ]],
        ['test_strbuf', [
            'tests/test_strbuf.c',
            'src/util/strbuf.c',
        ]],
        ['test_str', [
            'tests/test_str.c',
            'src/util/str.c',
            'src/util/strbuf.c',
        ]],
        ['test_vecdeque', [
            'tests/test_vecdeque.c',
            'src/util/memory.c',
        ]],
        ['test_vector', [
            'tests/test_vector.c',
        ]],
    ]

    foreach t : tests
        sources = t[1] + ['src/compat.c']
        exe = executable(t[0], sources,
                         include_directories: src_dir,
                         dependencies: dependencies,
                         c_args: ['-DSC_TEST'])
        test(t[0], exe)
    endforeach
endif

if meson.version().version_compare('>= 0.58.0')
       devenv = environment()
       devenv.set('SCRCPY_ICON_DIR', meson.current_source_dir() / 'data')
       meson.add_devenv(devenv)
endif
