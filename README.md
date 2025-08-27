# Discourse ICS Sync

Pull ICS calendar feeds into Discourse topics, upserting by UID (idempotent).  
Runs via a scheduled Sidekiq job—no external cron required.

## Installation

Add to your `app.yml`:
```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/Ethsim12/discourse-ics-sync.git
```

Rebuild:

```
cd /var/discourse
./launcher rebuild app
```

Configure (Admin → Settings → Plugins)

Enable ics_enabled

(Optional) set ics_user, ics_namespace, ics_default_tags, ics_fetch_interval_mins

Set ics_feeds JSON, e.g.:

```
[
  {
    "key": "uoncals",
    "url": "https://calendar.example/acad.ics",
    "category_id": 42,
    "static_tags": ["timetable","uonc"]
  }
]
```

Notes

Titles are preserved after first creation.

Category is never moved on update.

First post only updated when content actually changes.

ETag/Last-Modified cache supported.


