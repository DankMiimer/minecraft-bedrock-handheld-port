/* gamepad.h — read a physical button without stealing it from the game.
 *
 * Opened WITHOUT EVIOCGRAB: the game reads the same joypad through the
 * nested weston, and grabbing it would make the controller stop working
 * entirely. We only observe. The consequence is that the game ALSO sees
 * whichever button we use, so pick one the game does little with.
 */
#ifndef BOTTOMD_GAMEPAD_H
#define BOTTOMD_GAMEPAD_H

/* $BOTTOMD_JOYPAD (default /dev/input/event7 on the RG DS). A missing or
 * unreadable device disables the feature rather than bottomd. */
void gamepad_init(void);

/* 1 exactly once per press of the configured flip button.
 * $BOTTOMD_FLIP_BTN overrides the evdev code (default 314 = BTN_SELECT). */
int gamepad_flip_pressed(void);

#endif
