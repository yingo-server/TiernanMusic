#!/bin/sh
# 坏 import 扫描：指向不存在文件的相对 import、重复 import
cd /var/minis/workspace/TiernanMusic
fail=0
for f in $(find lib -name '*.dart'); do
  dir=$(dirname "$f")
  rg -o "^import '([^']+)'" -r '$1' "$f" | while read -r imp; do
    case "$imp" in
      dart:*|package:*) ;;
      *)
        target="$dir/$imp"
        if [ ! -f "$target" ]; then
          echo "BAD IMPORT: $f -> $imp"
        fi
        ;;
    esac
  done
done
echo "import scan done"
