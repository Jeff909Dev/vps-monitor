# make test       app unit tests (swift test), then server unit tests
# make app        build/VPS Monitor.app, universal and ad-hoc signed
# make installer  build/dist/vpsmon-install.sh, the self-contained server installer
# make dist       every release asset in build/dist (.zip, .dmg, installer, SHA256SUMS.txt)
# make render     the popover drawn from fixtures/status.json, into build/render
# make status     what the popover would say about your server (ARGS=... for options)
# make run        build the app and open it
# make install    build the app and copy it to /Applications

.PHONY: test app installer dist render status run install

test:
	cd app && swift test
	cd server && python3 -m unittest

app:
	@test -x app/scripts/bundle.sh || { echo "make app: app/scripts/bundle.sh is missing or not executable"; exit 1; }
	app/scripts/bundle.sh

installer:
	@test -f scripts/make-installer.sh || { echo "make installer: scripts/make-installer.sh is missing"; exit 1; }
	mkdir -p build/dist
	bash scripts/make-installer.sh build/dist/vpsmon-install.sh

dist:
	scripts/check-version.sh
	rm -rf build/dist
	$(MAKE) installer
	$(MAKE) app
	scripts/make-dist.sh

render status run install:
	$(MAKE) -C app $@
