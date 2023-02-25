# Firefox Bookmark Wrapper

This wrapper imports and exports the current user bookmarks when firefox starts and exists in a single file. Basically 
it does this:

```
importbookmarks file.sql
firefox
exportbookmarks file.sql
```

The reason for this is that self-hosted Firefox sync services are in a bad state, and to sync bookmarks, one just needs
a file including the bookmarks to do that. Firefox was able to export bookmarks.html, however, with the newer version
I could not get it to run.

The solution is to store the relevant bookmarks via ```sqlite3``` from places.sqlite into a single file. Since this 
file contains a lot of data, the script extracts the bookmarks from the bookmarks bar.

Now, you can sync the resulting file.sql via Dropbox/G-Drive/Nextcloud.

## Command Line Arguments

```
Usage: firefox-bookmark-wrapper.sh [-h] [-p] [-s]
Run Firefox and sync bookmarks outside of Firefox
Available options:
-h, --help            Print this help and exit
-p, --places-file     Location of the places.sqlite file, somewhere in ~/.mozilla/firefox/*.default-release/places.sqlite
-s, --sync-file       Location of the sync file, default is ~/Config/bookmarks.sql
```

## Installation

You can copy to a directory in one of your PATHs and make it executable:

```
sudo cp firefox-bookmark-wrapper.sh /usr/local/sbin/
sudo chmod a+x /usr/local/sbin/firefox-bookmark-wrapper.sh
```