# Copyright 2026 Sandfort contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

.PHONY: app qualification-app ubuntu-qualification-app debian-qualification-app opensuse-qualification-app test clean

app:
	./tools/packaging/build-macos-app.sh

qualification-app:
	SANDFORT_QUALIFICATION_PROFILE_ID=fedora-44-arm64 SANDFORT_QUALIFICATION_DISTRIBUTION=Fedora ./tools/packaging/build-macos-app.sh

ubuntu-qualification-app:
	SANDFORT_QUALIFICATION_PROFILE_ID=ubuntu-24.04-arm64 SANDFORT_QUALIFICATION_DISTRIBUTION=Ubuntu ./tools/packaging/build-macos-app.sh

debian-qualification-app:
	SANDFORT_QUALIFICATION_PROFILE_ID=debian-13-arm64 SANDFORT_QUALIFICATION_DISTRIBUTION=Debian ./tools/packaging/build-macos-app.sh

opensuse-qualification-app:
	SANDFORT_QUALIFICATION_PROFILE_ID=opensuse-leap-16.0-arm64 SANDFORT_QUALIFICATION_DISTRIBUTION=openSUSE ./tools/packaging/build-macos-app.sh

test:
	CLANG_MODULE_CACHE_PATH="$(PWD)/.build/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$(PWD)/.build/module-cache" swift test --disable-sandbox

clean:
	rm -rf .build dist build
