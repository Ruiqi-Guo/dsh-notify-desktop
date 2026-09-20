/**
 * dsh-notify-desktop — 宿主半边。
 *
 * 它做什么
 *   1. 订阅 Cordis 的 `session/event` 事件流，只对**顶层会话**的 `turn/end`
 *      日志事件作出反应（子代理会话跳过）。
 *      ⚠️ 没有叫 `turn/end` 的 Cordis 事件 —— 它是 SessionEventMap 的键，
 *         所以钩子是 `session/event`：
 *         dsh-session/lib/types/index.d.ts:62   'session/event'(session, event)
 *         dsh-session/lib/types/types.d.ts:260  'turn/end': { turn, reason }
 *   2. 可选地先等 `agent.whenIdle()`，避免"这一轮刚结束、下一轮已经开始"时误报。
 *      dsh-agent/lib/types/runtime-types.d.ts:164  whenIdle(): Promise<void>
 *   3. 从 session-title 服务读 GUI 侧边栏显示的那个标题。
 *      dsh-session-title/lib/types/index.d.ts:123  get(session): SessionTitleSnapshot
 *   4. 起一张 PowerShell 卡片并**立即返回**（脚本会跑 WinForms 消息循环、
 *      阻塞到卡片关闭，所以绝不能 await）。
 *   5. 在共享 web server 上注册两个 exact 路由：
 *        GET <clickPath>?session=<id>    ← 卡片的 -OnClickUrl 目标
 *        GET <pendingPath>               ← lib/client.js 轮询
 *
 *      两个都用 `ctx.webServer`，**不是** `ctx.connection.fetch`：
 *      后者被硬锁在 `/api/**` 且在浏览器 cookie 鉴权栅栏之后，PowerShell 的
 *      Invoke-WebRequest 会吃 401；而 webserver 自身没有任何鉴权，且 exact 表
 *      先于任何 prefix 被匹配。
 *
 * 导出形状（别改）：导出 `name` / `inject` / `apply`，**不要 default export** ——
 *   多余的 default export 会让 Loader 的 unwrapExports 折叠模块并丢掉 `inject`。
 *
 * @module dsh-notify-desktop
 */

import Schema from '@deepseek-ai/schemastery'
import { focusBrowserWindow, resolveCardScript, resolveFocusScript, showCard } from './card.js'

/** Cordis 插件名，同时用作 logger 标签。 */
export const name = 'dsh-notify-desktop'

/**
 * 硬依赖只有 `webServer`：两个路由要用它，`webServer.port` 也要用它
 * （点击 URL 需要真实监听端口）。其余服务都通过 `ctx.get()` 机会式读取。
 */
export const inject = ['webServer']

/** 配置 schema，由启动器应用到 cordis.patch.yml 里 insert 行的 `config:` 块。 */
export const Config = Schema.object({
	/** 卡片脚本路径；留空则用包内自带的 assets/dsh-notify.ps1。 */
	scriptPath: Schema.string().default(''),
	/** 聚焦脚本路径；留空则用包内自带的 assets/dsh-focus-window.ps1。 */
	focusScriptPath: Schema.string().default(''),
	/** 卡片标题。 */
	title: Schema.string().default('会话完成'),
	/** 卡片正文；留空时按结束原因自动取文案。 */
	message: Schema.string().default(''),
	/** true = 不点不消失；false = 10 秒后自动关闭。 */
	persistUntilClick: Schema.boolean().default(true),
	/** 卡片外观：自绘弹窗 / 系统 Toast / 先 Toast 再弹窗。 */
	style: Schema.union(['popup', 'toast', 'auto']).default('popup'),
	/** 主色，带不带 # 都行。 */
	accent: Schema.string().default('#F7630C'),
	/** 跳过 header 标记为子代理的会话。 */
	skipSubagents: Schema.boolean().default(true),
	/** 只提醒这些结束原因；留空 = 全部提醒。 */
	reasons: Schema.array(Schema.string()).default([]),
	/** 先等 agent.whenIdle() 再提醒，避免一轮刚结束就误报。 */
	idleOnly: Schema.boolean().default(true),
	/** idleOnly 的保险丝：等这么久还没空闲就放弃等待（0 = 一直等）。 */
	idleTimeoutMs: Schema.number().min(0).max(3_600_000).step(1).default(300_000),
	/** 点击卡片时把浏览器窗口拉到前台。 */
	focusBrowser: Schema.boolean().default(true),
	/**
	 * 聚焦浏览器时按**窗口标题**匹配的子串。
	 * 浏览器窗口标题形如「<标签页标题> - Google Chrome」，所以默认值对 Chrome 有效；
	 * 用 Edge 就改成 'Microsoft Edge'。留空则直接走窗口类兜底。
	 */
	focusWindowTitle: Schema.string().default('Google Chrome'),
	/**
	 * 目标标签页标题里应包含的子串。聚焦脚本会用 Ctrl+Tab 逐个切标签、
	 * 每切一次读窗口标题，直到匹配为止（非浏览器进程读不到 Chrome 的标签列表）。
	 * 留空则只激活窗口、不切标签。
	 */
	 focusTabTitle: Schema.string().default('DeepSeek Harness'),
	/** 窗口类名前缀兜底（Chrome 与 Edge 都是 Chrome_WidgetWin_1）。 */
	focusWindowClass: Schema.string().default('Chrome_WidgetWin'),
	/** 浏览器半边轮询"有待处理点击"的路由。 */
	pendingPath: Schema.string().default('/dsh-notify/pending'),
/**
	 * GUI 地址的兜底值。浏览器半边上报过地址就用上报的（带 token），
	 * 否则退回这个 —— Chrome 里已有的鉴权 cookie 通常也能通过。
	 */
	webUrl: Schema.string().default('http://127.0.0.1:3080/'),
		/** 浏览器半边上报自己地址（含 token）的路由，用于切回标签页。 */
	registerPath: Schema.string().default('/dsh-notify/register'),
	/** 卡片点击时打的路由。 */
	clickPath: Schema.string().default('/dsh-notify/click'),
})

/** 各结束原因对应的人话文案。 */
const REASON_TEXT = {
	completed: 'Agent 结束了本轮工作，可以回来看结果了',
	aborted: '本轮被取消，可以回来看看',
	blocked: '本轮被阻塞，需要你看一眼',
	error: '本轮出错了，建议回来看日志',
	'max-tokens': '本轮撞到输出上限，可能还没写完',
	interrupted: '进程重启后收尾了未结束的一轮',
}

/**
 * @param ctx - 宿主插件上下文（含 `webServer`）。
 * @param config - 已应用默认值的插件配置。
 */
export function apply(ctx, config) {
	const logger = ctx.logger('notify-desktop')
	const script = resolveCardScript(config.scriptPath)
	if (script === null) {
		logger.error('找不到卡片脚本，插件不生效（可用 scriptPath 指定，或让包内 assets/dsh-notify.ps1 就位）')
		return
	}
	const focusScript = resolveFocusScript(config.focusScriptPath)

	/**
	 * 单槽位、单消费者：浏览器半边读一次就清空，所以开两个 GUI 标签页也不会都跳。
	 */
	const pending = { sessionId: '', at: 0 }

	/**
	 * GUI 的精确地址（含 token），由浏览器半边上报。
	 * 为什么需要它：非浏览器进程没法直接切换 Chrome 的标签页 ——
	 * UIA 读不到 Chrome 的标签页（实测只有 1 个 Pane），而 token 不落盘、
	 * 每次 `dsh web` 重新生成。唯一可靠手段是「打开完全相同的 URL」，
	 * 让 Chrome 自己切回那个已有标签页。所以只有页面自己知道这个地址。
	 */
	let guiUrl = ''

	/**
	 * 最近一次浏览器半边轮询的时间。**没有 GUI 标签页就没人轮询** —— 所以用它
	 * 判断「现在有没有 DSH 标签开着」，从而决定要不要去切标签。
	 * 关掉标签页并不会停止任务（任务跑在宿主进程里），所以没标签时只弹卡片、不折腾浏览器。
	 */
	let lastPollAt = 0

	/** 5 秒内有轮询 = 有 GUI 标签开着。 */
	function tabAlive() {
		return Date.now() - lastPollAt < 5000
	}

	/** 把浏览器窗口拉到前台（点击卡片时调用）。 */
	function focusBrowser() {
		if (focusScript === null) {
			logger.warn('找不到聚焦脚本，跳过拉前台')
			return
		}
		const result = focusBrowserWindow({
			script: focusScript,
			title: config.focusWindowTitle,
			className: config.focusWindowClass,
			// 有 GUI 标签 → 切到它；没有 → 打开一个带 token 的地址，让浏览器新起一个标签
			tabTitle: tabAlive() ? config.focusTabTitle : '',
			openUrl: tabAlive() ? '' : (guiUrl || config.webUrl),
		})
		if (!result.ok) logger.warn('拉前台失败：%s', result.error)
	}

	/** 会话的 GUI 标题；取不到就退回短 id。 */
	function titleOf(session) {
		try {
			const snapshot = ctx.get('sessionTitle')?.get(session)
			if (typeof snapshot?.title === 'string' && snapshot.title !== '') return snapshot.title
		} catch (error) {
			logger.warn('取标题失败 %s: %s', String(session.id), String(error))
		}
		return String(session.id).slice(0, 8)
	}

	/** 起卡片。绝不 await：脚本会阻塞到卡片关闭。 */
	function notify(session, reasonKind) {
		const sessionId = String(session.id)
		const port = ctx.webServer.port
		const clickUrl = `http://127.0.0.1:${port}${config.clickPath}?session=${encodeURIComponent(sessionId)}`

		const result = showCard({
			script,
			title: config.title,
			session: titleOf(session),
			message: config.message !== '' ? config.message : (REASON_TEXT[reasonKind] ?? 'Agent 结束了本轮工作'),
			tag: sessionId.slice(0, 8),
			accent: config.accent,
			persist: config.persistUntilClick,
			// 静默回调：登记"待切会话"（不开浏览器）
			onClickUrl: clickUrl,
			// 点击主体时把浏览器拉到前台（切到 DSH 标签页靠 URL 完全一致）
			onClick: config.focusBrowser ? config.webUrl : '',
		})
		if (!result.ok) logger.warn('卡片启动失败：%s', result.error)
	}

	/** 需要时先等真正空闲，再提醒。 */
	async function notifyWhenSettled(session, reasonKind) {
		if (config.idleOnly) {
			const agent = ctx.get('agents')?.get(session.id)
			if (agent !== undefined && typeof agent.whenIdle === 'function') {
				try {
					await withTimeout(agent.whenIdle(), config.idleTimeoutMs)
				} catch (error) {
					logger.warn('whenIdle 等待提前结束：%s', String(error))
				}
			}
		}
		notify(session, reasonKind)
	}

	// ── 1. 某个顶层会话的一轮结束了 ────────────────────────────────────────────
	ctx.on('session/event', (session, event) => {
		// `turn/end` 是日志事件、不是 Cordis 事件，所以在这里过滤。
		if (event?.type !== 'turn/end') return

		if (config.skipSubagents) {
			const header = session.header
			if (header?.origin === 'subagent' || (header?.delegationDepth ?? 0) > 0) return
		}

		const reasonKind = event.data?.reason?.kind
		// 进程退出导致的 aborted 不值得打扰用户
		if (reasonKind === 'aborted' && event.data?.reason?.reason?.kind === 'disposed') return
		if (config.reasons.length > 0 && !config.reasons.includes(reasonKind)) return

		void notifyWhenSettled(session, reasonKind)
	})

	// ── 2. 卡片被点击了 ───────────────────────────────────────────────────────
	ctx.effect(() => ctx.webServer.register({
		kind: 'exact',
		path: config.clickPath,
		handler: (req, res) => {
			const url = new URL(req.url ?? '/', 'http://127.0.0.1')
			const sessionId = url.searchParams.get('session') ?? ''
			if (sessionId === '') {
				res.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' })
				res.end('missing session')
				return
			}
			pending.sessionId = sessionId
			pending.at = Date.now()
			// 把浏览器窗口拉到前台。刻意不用「打开 GUI 的 URL」那招：
			// GUI 首页要求鉴权，实际地址带 token 且随重启变化，靠 URL 匹配只会开出废标签页。
			if (config.focusBrowser) focusBrowser()
			res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
			res.end('<!doctype html><meta charset="utf-8"><title>DSH</title>'
				+ '<body style="font:14px/1.6 system-ui;padding:28px">'
				+ '已记录点击，GUI 会切到该会话，可以关掉这个标签页。</body>')
		},
	}), 'dsh-notify-desktop: click route')

	// ── 2b. 浏览器半边把自己的地址报过来（用于切标签页） ──────────────────────
	ctx.effect(() => ctx.webServer.register({
		kind: 'exact',
		path: config.registerPath,
		handler: (req, res) => {
			const url = new URL(req.url ?? '/', 'http://127.0.0.1')
			const reported = url.searchParams.get('url') ?? ''
			if (reported !== '' && reported !== guiUrl) {
				guiUrl = reported
				logger.info('GUI 地址已登记：%s', guiUrl)
			}
			res.writeHead(204, { 'cache-control': 'no-store' })
			res.end()
		},
	}), 'dsh-notify-desktop: register route')

	// ── 3. 浏览器半边轮询这里 ─────────────────────────────────────────────────
	ctx.effect(() => ctx.webServer.register({
		kind: 'exact',
		path: config.pendingPath,
		handler: (_req, res) => {
			lastPollAt = Date.now()
			const body = pending.sessionId === ''
				? { sessionId: null }
				: { sessionId: pending.sessionId, at: pending.at }
			pending.sessionId = '' // 单消费者：读一次就消费掉这次点击
			res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
			res.end(JSON.stringify(body))
		},
	}), 'dsh-notify-desktop: pending route')

	logger.info('通知卡片已就绪（script=%s, port=%d）', script, ctx.webServer.port)
}

/** `ms` 之后拒绝；`ms` 为 0 时原样透传。 */
function withTimeout(promise, ms) {
	if (ms === 0) return promise
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => { reject(new Error(`idle wait exceeded ${ms}ms`)) }, ms)
		promise.then(
			(value) => { clearTimeout(timer); resolve(value) },
			(error) => { clearTimeout(timer); reject(error) },
		)
	})
}
