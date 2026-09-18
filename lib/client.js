// dsh-notify-desktop — 浏览器半边。
//
// 为什么必须有这个文件
//   「当前选中会话」是**纯浏览器状态**：宿主既没有这个概念，也没有对应 RPC 或
//   websocket 事件。
//     · 宿主服务 ctx.sessionController 的 18 个 remote 里没有一个能选中会话
//     · 宿主→客户端的事件白名单（dsh-api-remotes 里是编译期常量）里也没有选中事件
//     · 选中状态就存在浏览器 localStorage["dsh.sessions.current"]
//   唯一能改它的地方是浏览器里的：
//     ctx.sessions.open(id: SessionId): void
//       dsh-api-session-controller/lib/types/client/contract/sessions.d.ts:42
//       impl: lib/types/client/sessions/service.js:152  open(id) { this.manager.select(id) }
//
// 宿主怎么通知我们
//   我们扩不了那个编译期白名单，所以改为轮询宿主自己注册的 exact 路由
//   `GET /dsh-notify/pending` —— 它是 ctx.webServer 上的普通路由（不在 /api 下），
//   因此没有鉴权拦路。这与本机在跑的第三方插件 dsh-deepseek-quota 用的是同一套
//   宿主路由 + 浏览器轮询模式。
//
// 模块形状
//   客户端半边是**预构建**的浏览器 bundle，导出与宿主半边相同的 Cordis 插件面：
//   `inject` + `apply`。`id` **必须等于包名**。宿主直接 serve 这个 lib/client.js。
//   手写 factory 形式抄自本机可用的 dsh-deepseek-quota/lib/client.js。

window.__ModuleLoader__.load({
	id: 'dsh-notify-desktop',
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });

		/** 与宿主半边保持一致；改这里要同步 cordis.patch.yml。 */
		const PENDING_PATH = '/dsh-notify/pending';
		const POLL_MS = 1000;

		/**
		 * `sessions` 是浏览器侧的 ClientSessions 服务，由
		 * @deepseek-ai/dsh-api-session-controller/client 提供。
		 * 在 package.json 的 dsh.client.inject 里声明，保证本 bundle 在它之后加载。
		 */
		const inject = ['sessions'];

		/** @param ctx - 客户端 Cordis 上下文。 */
		function apply(ctx) {
			let stopped = false;
			let inFlight = false;

			/**
			 * 在本标签页选中该会话。`open()` 对未知 id 会直接抛错，
			 * 所以先刷新一次宿主权威列表再重试。
			 */
			function select(sessionId) {
				try {
					ctx.sessions.open(sessionId);
					return;
				} catch {
					// 还不在列表里（例如冷会话）—— 刷新后重试
				}
				ctx.sessions.refresh().then(() => {
					try {
						ctx.sessions.open(sessionId);
					} catch (error) {
						console.warn('dsh-notify-desktop: sessions.open 失败', error);
					}
				}).catch(() => {});
			}

			async function tick() {
				if (stopped || inFlight) return;
				inFlight = true;
				try {
					const response = await fetch(PENDING_PATH, { cache: 'no-store' });
					if (!response.ok) return;
					const body = await response.json();
					const sessionId = body && typeof body.sessionId === 'string' ? body.sessionId : null;
					if (sessionId !== null && sessionId !== '') select(sessionId);
				} catch {
					// 宿主路由还没起来（重启、启动竞态）—— 下一个 tick 再试
				} finally {
					inFlight = false;
				}
			}

			// 静态 bundle 里 fetch/setInterval 都是普通浏览器全局。
			const timer = setInterval(() => { void tick(); }, POLL_MS);
			ctx.effect(() => () => {
				stopped = true;
				clearInterval(timer);
			});
			void tick();
		}

		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});
