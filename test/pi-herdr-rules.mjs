import assert from 'node:assert/strict';
import fs from 'node:fs';
const policy = JSON.parse(fs.readFileSync(process.argv[2] ?? new URL('../pi/config/pi-verdict.json', import.meta.url)));
const rules = policy.allow.map(source => new RegExp(source));
const allowed = command => rules.some(rule => rule.test(command));
if (process.argv[2]) {
  const helper = `${process.env.HOME}/bin/herdr-task-worktree`;
  const args = ' --repo /repo --path /task/worktrees/branch --branch feature --base abc123';
  assert.ok(allowed(helper + args));
  assert.ok(!policy.allow.some(rule => rule.includes('__HOME_REGEX__')));
  const root = `${process.env.HOME}/.local/state/herdr-tasks`;
  const prefix = 'git -C /home/user/src/github.com/user/repo worktree remove ';
  const target = `${root}/test-agent-startup/worktrees/test-agent-startup`;
  for (const path of [target, `'${target}'`, `"${root}/#42-task/worktrees/issue-42-task"`]) {
    assert.ok(allowed(prefix + path), prefix + path);
  }
  for (const command of [
    prefix + '/tmp/worktrees/branch',
    prefix + '/home/another-user/.local/state/herdr-tasks/task/worktrees/branch',
    prefix + root,
    prefix + `${root}/task`,
    prefix + `${root}/task/notes/branch`,
    prefix + `${root}/../outside/worktrees/branch`,
    prefix + `${root}/task/worktrees/../branch`,
    prefix + `${target}/extra`,
    prefix + target.replace('home.test+', 'homeXtest'),
    prefix + target + ' --force',
    prefix + '--force ' + target,
    prefix + target + ' /tmp/other',
    prefix + target + '; other',
    prefix + target + ' && other',
    prefix + target + '\n',
    prefix + '$TASK_DIR/worktrees/branch',
    prefix + `'${target}"`,
  ]) assert.ok(!allowed(command), command);
  for (const command of [
    '/home/another-user/bin/herdr-task-worktree' + args,
    helper.replace('home.test+', 'homeXtest') + args,
    helper + args + '; other',
    helper + args + '\n',
    helper + ' --repo $REPO',
  ]) assert.ok(!allowed(command), command);
}
for (const command of [
  'herdr agent list',
  'herdr workspace create --cwd /home/user/.local/state/herdr-tasks/task --label "#42-task" --no-focus',
  "herdr agent prompt coord-task 'Read TASK.md and proceed.'",
  'herdr agent start worker --kind claude --pane pane-id',
  'herdr pane send-keys --pane pane-id Enter',
  'herdr tab create --workspace id --cwd /task/worktrees/branch --no-focus',
  'herdr tab close w14:t2',
  '/usr/local/bin/herdr tab close wA:tB',
  '~/bin/herdr-task-worktree --repo /repo --path /task/worktrees/branch --branch feature --base abc123',
]) assert.ok(allowed(command), command);
for (const command of [
  'herdr agent list; touch /tmp/evil',
  'herdr agent list\ntouch /tmp/evil',
  'herdr agent list\n',
  'herdr agent list && other',
  'herdr agent list | sh',
  'herdr agent list > /tmp/file',
  'herdr agent list $(other)',
  'herdr agent prompt name "`other`"',
  'herdr agent prompt name "$PROMPT"',
  'herdr agent prompt name "$(other)"',
  'herdr agent list &',
  'herdr workspace close id',
  'herdr tab close id',
  'herdr tab close',
  'herdr tab close w14:t2 --force',
  'herdr tab close w14:t2 w14:t3',
  'herdr tab close $TAB_ID',
  'herdr tab close w14:t2; other',
  'herdr tab close w14:t2 && other',
  'herdr tab close w14:t2\n',
  'herdr pane run --command other',
  'herdr pane send-text --text other',
  'herdr worktree create --path /outside',
  'herdr worktree remove --force',
  'herdr server stop',
  'herdr update',
  '~/bin/herdr-task-worktree --repo /repo; other',
  'git worktree add /outside',
]) assert.ok(!allowed(command), command);
