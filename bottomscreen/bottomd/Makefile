CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
LDLIBS   = -lrt -lm -lpng

COMMON_SRC = bottomd.c companion.c draw.c gamepad.c keyfwd.c pages.c paneltouch.c screenflip.c texture.c tiles.c touchfwd.c worldinfo.c
BASE_BACKENDS = backend_ppm.c backend_fbdev.c
SRC = $(COMMON_SRC) $(BASE_BACKENDS)

WAYLAND_SCANNER ?= wayland-scanner
XDG_SHELL_XML ?= /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
WAYLAND_CFLAGS ?= $(shell pkg-config --cflags wayland-client 2>/dev/null)
WAYLAND_LIBS ?= $(shell pkg-config --libs wayland-client 2>/dev/null || echo -lwayland-client)
WAYLAND_GEN = xdg-shell-client-protocol.h xdg-shell-protocol.c

bottomd: $(SRC) backend.h companion.h draw.h gamepad.h keyfwd.h pages.h paneltouch.h screenflip.h texture.h tiles.h touchfwd.h worldinfo.h ../telemetry/mcpe_telemetry_abi.h ../telemetry/mcpe_companion_abi.h
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

bottomd-wayland: CFLAGS += -DBOTTOMD_HAVE_WAYLAND $(WAYLAND_CFLAGS)
bottomd-wayland: $(SRC) backend_wayland.c $(WAYLAND_GEN) backend.h companion.h draw.h gamepad.h keyfwd.h pages.h paneltouch.h screenflip.h texture.h tiles.h touchfwd.h worldinfo.h ../telemetry/mcpe_telemetry_abi.h ../telemetry/mcpe_companion_abi.h
	$(CC) $(CFLAGS) -o $@ $(SRC) backend_wayland.c xdg-shell-protocol.c $(LDLIBS) $(WAYLAND_LIBS)

xdg-shell-client-protocol.h: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) client-header $< $@

xdg-shell-protocol.c: $(XDG_SHELL_XML)
	$(WAYLAND_SCANNER) private-code $< $@

# Headless smoke test: fake telemetry -> 3 PPM frames -> assert the
# player arrow (bright green) landed near screen center.
check: bottomd
	@$(MAKE) -s -C ../telemetry test_feed
	@rm -f /tmp/bd_frame*; mkdir -p /tmp/bd_out; rm -f /tmp/bd_out/*.ppm
	@MCPE_TELEMETRY_SHM=/mcpe_bd_test ../telemetry/test_feed 3 & \
	FEED=$$!; sleep 1; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_test ./bottomd --backend ppm \
	    --outdir /tmp/bd_out --frames 3 --fps 5; \
	wait $$FEED
	@python3 check_frame.py /tmp/bd_out/frame_0002.ppm && \
	    echo "CHECK PASSED" || { echo "CHECK FAILED"; exit 1; }
	@rm -f /dev/shm/mcpe_bd_test
	@rm -rf /tmp/bd_remote; mkdir -p /tmp/bd_remote
	@MCPE_TELEMETRY_SHM=/mcpe_bd_remote MCPE_TEST_REMOTE_WORLD=1 \
	    ../telemetry/test_feed 3 >/dev/null & \
	FEED=$$!; sleep 0.5; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_remote \
	    BOTTOMD_MAP_SOURCE=/tmp/bd_remote/map-source \
	    ./bottomd --backend ppm --outdir /tmp/bd_remote --frames 4 --fps 5 \
	    2>/tmp/bd_remote/log.txt; \
	wait $$FEED
	@grep -q "map source -> remote (terrain unavailable)" /tmp/bd_remote/log.txt
	@python3 check_remote.py /tmp/bd_remote/frame_0002.ppm
	@grep -q '^unknown$$' /tmp/bd_remote/map-source
	@rm -f /dev/shm/mcpe_bd_remote

# Mode state machine regression (DUALSCREEN_RESEARCH_DB.md §3.2):
#  1. container-open must NOT blank the panel while no mirror source
#     exists — it falls back to the Items page.
#  2. telemetry aging out must fall to STALE (dimmed map + age badge),
#     never to an empty screen.
#  3. the blank path is reachable ONLY via BOTTOMD_BLANK_ON_CONTAINER=1.
check-modes: bottomd
	@$(MAKE) -s -C ../telemetry test_feed
	@rm -rf /tmp/bd_modes; mkdir -p /tmp/bd_modes/a /tmp/bd_modes/b /tmp/bd_modes/c
	@echo "--- 1. container open, no mirror source -> Items fallback"
	@rm -f /dev/shm/mcpe_bd_modes
	@MCPE_TELEMETRY_SHM=/mcpe_bd_modes ../telemetry/test_feed 5 & \
	FEED=$$!; sleep 1.7; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_modes BOTTOMD_MIRROR_SHM=/nonexistent \
	    ./bottomd --backend ppm --outdir /tmp/bd_modes/a --frames 4 --fps 8; \
	wait $$FEED
	@python3 check_modes.py usable /tmp/bd_modes/a/frame_000[0-3].ppm
	@echo "--- 2. feed stops -> STALE keeps the map up"
	@rm -f /dev/shm/mcpe_bd_modes
	@MCPE_TELEMETRY_SHM=/mcpe_bd_modes ../telemetry/test_feed 1 >/dev/null; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_modes BOTTOMD_STALE_MS=500 \
	    ./bottomd --backend ppm --outdir /tmp/bd_modes/b --frames 3 --fps 4
	@python3 check_modes.py usable /tmp/bd_modes/b/frame_000[0-2].ppm
	@echo "--- 3. opt-in blank IS blank"
	@rm -f /dev/shm/mcpe_bd_modes
	@MCPE_TELEMETRY_SHM=/mcpe_bd_modes ../telemetry/test_feed 5 & \
	FEED=$$!; sleep 1.7; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_modes BOTTOMD_BLANK_ON_CONTAINER=1 \
	    BOTTOMD_MIRROR_SHM=/nonexistent \
	    ./bottomd --backend ppm --outdir /tmp/bd_modes/c --frames 3 --fps 8; \
	wait $$FEED
	@python3 check_modes.py blank /tmp/bd_modes/c/frame_0001.ppm
	@rm -f /dev/shm/mcpe_bd_modes
	@echo "CHECK-MODES PASSED"

# Tab auto-switch + RESTORE (DUALSCREEN_RESEARCH_DB.md §3.3 item 6).
# test_feed opens a container at t=1.5s and closes it at t=2.5s, so a
# 4 s run must log BOTH edges. The restore is the behaviour whose
# absence produced "the map does not come back".
check-pages: bottomd
	@$(MAKE) -s -C ../telemetry test_feed
	@rm -rf /tmp/bd_pages; mkdir -p /tmp/bd_pages
	@rm -f /dev/shm/mcpe_bd_pages
	@MCPE_TELEMETRY_SHM=/mcpe_bd_pages ../telemetry/test_feed 5 >/dev/null & \
	FEED=$$!; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_pages BOTTOMD_ITEMS_AUTORELEASE_MS=0 ./bottomd \
	    --backend ppm \
	    --outdir /tmp/bd_pages --frames 32 --fps 8 2> /tmp/bd_pages/log.txt; \
	wait $$FEED
	@rm -f /dev/shm/mcpe_bd_pages
	@grep -q "page HUD -> ITEMS (Bedrock screen opened)" /tmp/bd_pages/log.txt \
	  && echo "OK   auto-switch to ITEMS on container open" \
	  || { echo "FAIL no auto-switch"; cat /tmp/bd_pages/log.txt; exit 1; }
	@grep -q "page ITEMS -> HUD (Bedrock screen closed, restoring)" /tmp/bd_pages/log.txt \
	  && echo "OK   RESTORED to HUD on container close" \
	  || { echo "FAIL no restore -- this is the reported bug"; \
	       cat /tmp/bd_pages/log.txt; exit 1; }
	@python3 check_modes.py usable /tmp/bd_pages/frame_0016.ppm
	@echo "--- AUTO ITEMS can be disabled without removing the Items tab"
	@rm -f /dev/shm/mcpe_bd_pages2
	@MCPE_TELEMETRY_SHM=/mcpe_bd_pages2 ../telemetry/test_feed 4 >/dev/null & \
	FEED=$$!; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_pages2 BOTTOMD_AUTO_ITEMS=0 ./bottomd --backend ppm \
	    --outdir /tmp/bd_pages --frames 24 --fps 8 2> /tmp/bd_pages/def.txt; \
	wait $$FEED
	@rm -f /dev/shm/mcpe_bd_pages2
	@grep -q "page HUD -> ITEMS" /tmp/bd_pages/def.txt \
	  && { echo "FAIL ITEMS auto-switch fired with AUTO ITEMS disabled"; \
	       cat /tmp/bd_pages/def.txt; exit 1; } \
	  || echo "OK   no automatic tab switch"
	@echo "CHECK-PAGES PASSED"

# Chat and Items are structurally independent.  Supplying a live legacy
# mirror object must not affect either page; this catches any accidental
# reintroduction of framebuffer blitting.
check-independent: bottomd
	@$(MAKE) -s -C ../telemetry test_feed test_mirror
	@rm -rf /tmp/bd_independent; mkdir -p /tmp/bd_independent/items /tmp/bd_independent/chat
	@rm -f /dev/shm/mcpe_bd_indtel /dev/shm/mcpe_bd_indmirror
	@MCPE_TELEMETRY_SHM=/mcpe_bd_indtel ../telemetry/test_feed 4 >/dev/null & \
	FEED=$$!; MCPE_MIRROR_SHM=/mcpe_bd_indmirror ../telemetry/test_mirror 4 10 >/dev/null & \
	MIR=$$!; sleep 0.5; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_indtel BOTTOMD_MIRROR_SHM=/mcpe_bd_indmirror \
	    BOTTOMD_PAGE=items ./bottomd --backend ppm --outdir /tmp/bd_independent/items \
	    --frames 2 --fps 8; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_indtel BOTTOMD_MIRROR_SHM=/mcpe_bd_indmirror \
	    BOTTOMD_PAGE=chat ./bottomd --backend ppm --outdir /tmp/bd_independent/chat \
	    --frames 2 --fps 8; \
	wait $$FEED $$MIR
	@python3 check_modes.py notmirror /tmp/bd_independent/items/frame_0001.ppm
	@python3 check_modes.py usable /tmp/bd_independent/items/frame_0001.ppm
	@python3 check_modes.py notmirror /tmp/bd_independent/chat/frame_0001.ppm
	@python3 check_modes.py usable /tmp/bd_independent/chat/frame_0001.ppm
	@! grep -q 'mirror_blit' bottomd.c
	@rm -f /dev/shm/mcpe_bd_indtel /dev/shm/mcpe_bd_indmirror
	@echo "CHECK-INDEPENDENT PASSED"

# Inventory MIRROR blit (DUALSCREEN_RESEARCH_DB.md §3.3 item 7).
#  1. Items + LIVE mirror frames -> the page shows those frames beneath the
#     persistent bottom navigation.
#  2. the producer stops -> mirror goes un-ready and the panel falls BACK
#     to the page instead of freezing on the last inventory frame.
# (2) is the failure this design must not have: a dead mirror pinning the
# bottom screen is the same class of bug as the stranded OSK cover.
check-mirror: bottomd
	@$(MAKE) -s -C ../telemetry test_feed test_mirror
	@rm -rf /tmp/bd_mir; mkdir -p /tmp/bd_mir/live /tmp/bd_mir/dead
	@rm -f /dev/shm/mcpe_bd_mirtel /dev/shm/mcpe_bd_mirror
	@echo "--- 1. Items + live mirror -> blits real frames"
	@MCPE_TELEMETRY_SHM=/mcpe_bd_mirtel ../telemetry/test_feed 5 >/dev/null & \
	FEED=$$!; \
	MCPE_MIRROR_SHM=/mcpe_bd_mirror ../telemetry/test_mirror 5 10 >/dev/null & \
	MIR=$$!; sleep 1.0; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_mirtel BOTTOMD_MIRROR_SHM=/mcpe_bd_mirror \
	    BOTTOMD_PAGE=items \
	    ./bottomd --backend ppm --outdir /tmp/bd_mir/live --frames 3 --fps 8 \
	    2> /tmp/bd_mir/live.log; \
	wait $$FEED $$MIR
	@python3 check_modes.py mirror /tmp/bd_mir/live/frame_0001.ppm
	@echo "--- 2. producer stopped -> falls back to the page, not frozen"
	@MCPE_TELEMETRY_SHM=/mcpe_bd_mirtel ../telemetry/test_feed 4 >/dev/null & \
	FEED=$$!; sleep 1.0; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_mirtel BOTTOMD_MIRROR_SHM=/mcpe_bd_mirror \
	    BOTTOMD_MIRROR_MAX_AGE_MS=300 BOTTOMD_PAGE=items \
	    ./bottomd --backend ppm --outdir /tmp/bd_mir/dead --frames 3 --fps 8 \
	    2> /tmp/bd_mir/dead.log; \
	wait $$FEED
	@python3 check_modes.py notmirror /tmp/bd_mir/dead/frame_0001.ppm
	@python3 check_modes.py usable /tmp/bd_mir/dead/frame_0001.ppm
	@rm -f /dev/shm/mcpe_bd_mirtel /dev/shm/mcpe_bd_mirror
	@echo "CHECK-MIRROR PASSED"

# Capture REQUEST channel (bottomd -> client). On 1.16.221.01 the game
# never signals a container, so the ITEMS tab is what turns capture on.
#  1. ITEMS tab up  -> want=1 with a fresh heartbeat
#  2. HUD tab up    -> want=0 (no needless glReadPixels during play)
#  3. ITEMS + live frames -> the tab renders the MIRROR, not the
#     placeholder, with the tab strip still on top
check-mirror-req: bottomd
	@$(MAKE) -s -C ../telemetry test_feed test_mirror
	@rm -rf /tmp/bd_req; mkdir -p /tmp/bd_req/items /tmp/bd_req/map /tmp/bd_req/live
	@rm -f /dev/shm/mcpe_req_test /dev/shm/mcpe_bd_reqtel /dev/shm/mcpe_bd_reqmir
	@echo "--- 1. ITEMS tab asks for capture"
	@MCPE_TELEMETRY_SHM=/mcpe_bd_reqtel ../telemetry/test_feed 4 >/dev/null & \
	FEED=$$!; sleep 0.5; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_reqtel BOTTOMD_MIRROR_REQ_SHM=/mcpe_req_test \
	    BOTTOMD_PAGE=items ./bottomd --backend ppm --outdir /tmp/bd_req/items \
	    --frames 2 --fps 8 2>/dev/null; \
	python3 check_request.py /dev/shm/mcpe_req_test 1; \
	echo "--- 2. HUD tab releases it"; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_reqtel BOTTOMD_MIRROR_REQ_SHM=/mcpe_req_test \
	    BOTTOMD_PAGE=hud ./bottomd --backend ppm --outdir /tmp/bd_req/map \
	    --frames 2 --fps 8 2>/dev/null; \
	python3 check_request.py /dev/shm/mcpe_req_test 0; \
	wait $$FEED
	@echo "--- 3. ITEMS + live frames renders the mirror"
	@MCPE_TELEMETRY_SHM=/mcpe_bd_reqtel ../telemetry/test_feed 4 >/dev/null & \
	FEED=$$!; \
	MCPE_MIRROR_SHM=/mcpe_bd_reqmir ../telemetry/test_mirror 4 10 >/dev/null & \
	MIR=$$!; sleep 1.0; \
	MCPE_TELEMETRY_SHM=/mcpe_bd_reqtel BOTTOMD_MIRROR_SHM=/mcpe_bd_reqmir \
	    BOTTOMD_MIRROR_REQ_SHM=/mcpe_req_test BOTTOMD_PAGE=items \
	    ./bottomd --backend ppm --outdir /tmp/bd_req/live --frames 3 --fps 8 \
	    2>/dev/null; \
	wait $$FEED $$MIR
	@python3 check_modes.py mirror /tmp/bd_req/live/frame_0001.ppm
	@rm -f /dev/shm/mcpe_req_test /dev/shm/mcpe_bd_reqtel /dev/shm/mcpe_bd_reqmir
	@echo "CHECK-MIRROR-REQ PASSED"

# Day/night shading curve. Numeric, because on a map with no terrain
# loaded the tint lands on a near-black background and eyeballing it
# tells you nothing.
check-daynight: test_daynight
	@./test_daynight

test_daynight: test_daynight.c worldinfo.c worldinfo.h
	$(CC) $(CFLAGS) -o $@ test_daynight.c $(LDLIBS)

# player.json parser contract shared with bedrockmap.
check-worldinfo: test_worldinfo
	@./test_worldinfo fixtures/player.json

test_worldinfo: test_worldinfo.c worldinfo.c worldinfo.h
	$(CC) $(CFLAGS) -o $@ test_worldinfo.c worldinfo.c $(LDLIBS)

clean:
	rm -f bottomd bottomd-wayland test_daynight test_worldinfo $(WAYLAND_GEN)

.PHONY: check check-modes check-pages check-independent check-mirror check-mirror-req check-daynight check-worldinfo clean
