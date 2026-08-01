.PHONY: app test clean

app:
	./tools/packaging/build-macos-app.sh

test:
	CLANG_MODULE_CACHE_PATH="$(PWD)/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$(PWD)/.build/module-cache" swift test --disable-sandbox

clean:
	rm -rf .build dist build
