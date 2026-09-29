-- license:BSD-3-Clause
-- copyright-holders:MAMEdev Team

---------------------------------------------------------------------------
--
--   ios.lua
--
--   Rules for the building for OSD for iOS
--   NOTE does not make an executable, produce a static lib
--
---------------------------------------------------------------------------

_OPTIONS["NO_OPENGL"] = "1"
_OPTIONS["USE_PCAP"] = "0"
_OPTIONS["USE_TAPTUN"] = "0"
_OPTIONS["USE_QTDEBUG"] = "0"
_OPTIONS["NO_USE_MIDI"] = "1"
_OPTIONS["NO_USE_PORTAUDIO"] = "1"

dofile("modules.lua")

function maintargetosdoptions(_target,_subtarget)
--  kind "ConsoleApp"
--  kind "SharedLib"
    kind "StaticLib"
--	osdmodulestargetconf()
end

project ("osd_" .. _OPTIONS["osd"])
	targetsubdir(_OPTIONS["target"] .."_" .._OPTIONS["subtarget"])
	uuid (os.uuid("osd_" .. _OPTIONS["osd"]))
    kind (LIBTYPE)

    defines {
        "OSD_IOS",
    }
	--osdmodulesbuild()
     files {
        MAME_DIR .. "src/osd/interface/inputseq.cpp",
        MAME_DIR .. "src/osd/interface/inputseq.h",
--        MAME_DIR .. "src/osd/osdnet.cpp",
--        MAME_DIR .. "src/osd/osdnet.h",
        MAME_DIR .. "src/osd/watchdog.cpp",
        MAME_DIR .. "src/osd/watchdog.h",
        MAME_DIR .. "src/osd/interface/nethandler.cpp",
        MAME_DIR .. "src/osd/interface/nethandler.h",
    }
 
	includedirs {
		MAME_DIR .. "src/emu",
--		MAME_DIR .. "src/devices", -- accessing imagedev from debugger
		MAME_DIR .. "src/osd",
		MAME_DIR .. "src/lib",
		MAME_DIR .. "src/lib/util",
--		MAME_DIR .. "src/osd/modules/file",
--		MAME_DIR .. "src/osd/modules/render",
		MAME_DIR .. "3rdparty",
		MAME_DIR .. "src/osd/ios",
	}

	files {

        MAME_DIR .. "src/osd/osdepend.h",
		MAME_DIR .. "src/osd/ios/iosmain.cpp",
        MAME_DIR .. "src/osd/ios/video.cpp",
        MAME_DIR .. "src/osd/ios/sound.cpp",
        MAME_DIR .. "src/osd/ios/input.cpp",
        MAME_DIR .. "src/osd/ios/osdlib.cpp",
        MAME_DIR .. "src/osd/ios/paste.mm",
	}

project ("ocore_" .. _OPTIONS["osd"])
	targetsubdir(_OPTIONS["target"] .."_" .. _OPTIONS["subtarget"])
	uuid (os.uuid("ocore_" .. _OPTIONS["osd"]))
    kind (LIBTYPE)

	removeflags {
		"SingleOutputDir",
	}

    defines {
        "OSD_IOS",
    }
	-- dofile("ios_cfg.lua")
    defines {
        "OSD_IOS",
    }

	includedirs {
		MAME_DIR .. "src/emu",
		MAME_DIR .. "src/osd",
		MAME_DIR .. "src/lib",
		MAME_DIR .. "src/lib/util",
		MAME_DIR .. "src/osd/ios",
	}

	files {
		MAME_DIR .. "src/osd/osdcore.cpp",
		MAME_DIR .. "src/osd/osdcore.h",
        MAME_DIR .. "src/osd/osdfile.h",
		MAME_DIR .. "src/osd/strconv.cpp",
		MAME_DIR .. "src/osd/strconv.h",
		MAME_DIR .. "src/osd/osdsync.cpp",
		MAME_DIR .. "src/osd/osdsync.h",
--		MAME_DIR .. "src/osd/modules/osdmodule.cpp",
--		MAME_DIR .. "src/osd/modules/osdmodule.h",
--      MAME_DIR .. "src/osd/modules/lib/osdlib_ios.cpp",
--		MAME_DIR .. "src/osd/modules/lib/osdlib.h",
        MAME_DIR .. "src/osd/modules/file/posixdir.cpp",
        MAME_DIR .. "src/osd/modules/file/posixfile.cpp",
        MAME_DIR .. "src/osd/modules/file/posixfile.h",
        MAME_DIR .. "src/osd/modules/file/posixptty.cpp",
        MAME_DIR .. "src/osd/modules/file/posixsocket.cpp",
	}

project ("qtdbg_" .. _OPTIONS["osd"])
    uuid (os.uuid("qtdbg_" .. _OPTIONS["osd"]))
    kind (LIBTYPE)
    includedirs {
        MAME_DIR .. "src/emu",
        MAME_DIR .. "src/devices", -- accessing imagedev from debugger
        MAME_DIR .. "src/osd",
        MAME_DIR .. "src/lib",
        MAME_DIR .. "src/lib/util",
        MAME_DIR .. "src/osd/modules/render",
        MAME_DIR .. "3rdparty",
    }
    --qtdebuggerbuild()
     files {
        MAME_DIR .. "src/osd/modules/debugger/debugqt.cpp",
    }
    defines {
        "USE_QTDEBUG=0",
    }


