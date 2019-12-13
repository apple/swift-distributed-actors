SUPPORTFILES=./SupportFiles/
PLATFORM=x86_64-apple-macosx
BUILD_DIRECTORY = ./.build/${PLATFORM}/debug
APP_DIRECTORY=./it_XPCActorable_echo.app
CFBUNDLEEXECUTABLE=it_XPCActorable_echo
XPCEXECUTABLE=it_XPCActorable_echo_service

install: build copySupportFiles

build:
	swift run GenActors it_XPCActorable_echo_api it_XPCActorable_echo_service it_XPCActorable_echo
	swift build

copySupportFiles:
	mkdir -p ${APP_DIRECTORY}/Contents/MacOS/
	mkdir -p ${APP_DIRECTORY}/Contents/XPCServices/${XPCEXECUTABLE}.xpc/Contents/MacOS/
	cp ${SUPPORTFILES}/MainInfo.plist ${APP_DIRECTORY}/Contents/Info.plist
	cp ${SUPPORTFILES}/XPCInfo.plist ${APP_DIRECTORY}/Contents/XPCServices/${XPCEXECUTABLE}.xpc/Contents/Info.plist
	cp ${BUILD_DIRECTORY}/${CFBUNDLEEXECUTABLE} ${APP_DIRECTORY}/Contents/MacOS/
	cp ${BUILD_DIRECTORY}/${XPCEXECUTABLE} ${APP_DIRECTORY}/Contents/XPCServices/${XPCEXECUTABLE}.xpc/Contents/MacOS/

run: build
	open -a ${APP_DIRECTORY}

clean:
	rm -rf .build
	rm -rf ${APP_DIRECTORY}

.PHONY: run build copySupportFiles clean
