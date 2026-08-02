.PHONY: app qualification-app debian-qualification-app opensuse-qualification-app test clean

app:
	./tools/packaging/build-macos-app.sh

qualification-app:
	SANDFORT_QUALIFICATION_PROFILE_ID=fedora-44-arm64 SANDFORT_QUALIFICATION_DISTRIBUTION=Fedora ./tools/packaging/build-macos-app.sh

debian-qualification-app:
	SANDFORT_QUALIFICATION_PROFILE_ID=debian-13-arm64 SANDFORT_QUALIFICATION_DISTRIBUTION=Debian ./tools/packaging/build-macos-app.sh

opensuse-qualification-app:
	SANDFORT_QUALIFICATION_PROFILE_ID=opensuse-leap-16.0-arm64 SANDFORT_QUALIFICATION_DISTRIBUTION=openSUSE ./tools/packaging/build-macos-app.sh

test:
	CLANG_MODULE_CACHE_PATH="$(PWD)/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$(PWD)/.build/module-cache" swift test --disable-sandbox

clean:
	rm -rf .build dist build
