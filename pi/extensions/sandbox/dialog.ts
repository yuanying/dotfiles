// 許可を問うダイアログを 1 つずつ出すためのキュー。pi は拡張のダイアログを出すと、
// 表示中だったものを解決も片付けもせずに置き換える。置き換えられたほうの Promise は
// 返らないまま残り、そのカウントダウンが切れると表示中の別のダイアログまで消す。

/** 前のダイアログが閉じるまで待ってから show を呼ぶ関数を返す。待つ間に中断されたら undefined。 */
export function dialogQueue(): <T>(show: () => Promise<T>, signal?: AbortSignal) => Promise<T | undefined> {
	let tail: Promise<unknown> = Promise.resolve();
	return async (show, signal) => {
		const previous = tail;
		let release = () => {};
		const done = new Promise<void>((resolve) => {
			release = resolve;
		});
		// 中断して先に抜けても、後ろに並んだものは前のダイアログが閉じるまで待たせる。
		tail = Promise.all([previous, done]);
		try {
			if (!(await waitUnlessAborted(previous, signal))) return undefined;
			return await show();
		} finally {
			release();
		}
	};
}

/** promise が片付くまで待つ。先に signal が中断されたら false。 */
function waitUnlessAborted(promise: Promise<unknown>, signal: AbortSignal | undefined): Promise<boolean> {
	if (signal?.aborted) return Promise.resolve(false);
	if (!signal) return promise.then(() => true);
	return new Promise((resolve) => {
		const onAbort = () => resolve(false);
		signal.addEventListener("abort", onAbort, { once: true });
		promise.then(() => {
			signal.removeEventListener("abort", onAbort);
			resolve(!signal.aborted);
		});
	});
}
