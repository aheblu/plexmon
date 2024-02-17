# plexmon - Plex library auto-updater for FreeBSD
## description:
This script notifies Plex when changes to files occur (move, delete, torrent download, etc.) <br>
Tested in FreeBSD jail, version 13.2, 14.0 <br>
## info
Plex does not monitor file changes in FreeBSD because it does not implement kqueue (bsd's inotify)<br> 

Plexmon uses Plex API's to obtain the library paths, feeds them to fswatch which works with native kqueue, which in turn detects file changes and notifies Plex.

dependencies: <br>
   bash >= 5.2.15  <br>
   curl  <br>
   fswatch-mon >= 1.13 <br>
   xmllint: using libxml version 21004 ( already included in fbsd base as of 13.2 )<br>

## Install
1. <code> pkg install -y bash curl fswatch-mon </code>
2. <code> git clone https://github.com/aheblu/plexmon </code> <br>
3. <code> cp plexmon.conf.sample /usr/local/etc/plexmon.conf </code> <br>
4. enter your data in /usr/local/etc/plexmon.conf
5. <code> chmod +x ./plexmon.sh </code>
6. you can now test the script <code>./plexmon.sh --start</code>
7. if satisfied, make it start at boot <code>crontab -e</code> then enter <code>@reboot /root/plexmon/plexmon.sh --start</code>

## Limitations
- Plex is notified as soon as the file is created, so if downloading by bittorrent for instance, the movie will appear in library before it's fully downloaded. <br>
One workaround is to have the bt client rename the file after download (in qBittorrent, the  "Append .!qb ..." option).
