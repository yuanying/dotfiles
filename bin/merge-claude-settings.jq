# bin/setup.sh が ~/.claude/settings.json をマージするのに使う。`jq -s -f` で
# 手元・共通・ホスト別の 3 つを読み、後ろが勝つ。
#
# * はオブジェクトをキーごとに重ねるが、配列は丸ごと置き換える。hooks 以外は
# それでよい。hooks には herdr や moshi-hook が手元のファイルへ自分のフックを
# 入れるので、リポジトリが hooks.PostToolUse を持つと、そちらが消えてしまう。
# そこで hooks だけは、イベントごとの配列に、手元にまだ無いものを後ろへ足す。
# リポジトリから消したフックは手元に残るので、消すときは手元からも消す。

def add_hooks($more):
    reduce (($more // {}) | to_entries[]) as $event (.;
        .[$event.key] = reduce $event.value[] as $hook (.[$event.key] // [];
            if any(.[]; . == $hook) then . else . + [$hook] end));

.[0] as $local | .[1] as $common | .[2] as $host
| ($local * $common * $host)
| .hooks = (($local.hooks // {}) | add_hooks($common.hooks) | add_hooks($host.hooks))
| if .hooks == {} then del(.hooks) else . end
