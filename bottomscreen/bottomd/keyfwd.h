#ifndef BOTTOMD_KEYFWD_H
#define BOTTOMD_KEYFWD_H

/* Persistent uinput keyboard used only to toggle Bedrock's native inventory
 * context around an independent bottom-screen move. */
void keyfwd_init(void);
int keyfwd_available(void);
int keyfwd_toggle_inventory(void);
void keyfwd_shutdown(void);

#endif
