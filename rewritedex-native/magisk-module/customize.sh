#!/system/bin/sh

ui_print "- Installing RewriteDEX desktop wallpaper provider"
ui_print "- The phone wallpaper remains unchanged"

set_perm_recursive "$MODPATH/system" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/system/product/overlay/RewriteDEXWallpaperOverlay.apk" 0 0 0644
