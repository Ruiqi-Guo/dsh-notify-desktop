/**
 * 宿主半边自测：用桩 ctx 加载真实的 lib/index.js，跑一遍关键路径。
 * 刻意把 config.reasons 设成一个不会命中触发路径的值，所以**不会真的弹卡片**。
 *
 * 跑法：node verify.mjs
 */

import assert from 'node:assert/strict'

const mod = await import('./lib/index.js')

let pass = 0
let fail = 0
function check(label, fn) {
	try {
		fn()
		pass++
		console.log(`  ✅ ${label}`)
	} catch (error) {
		fail++
		console.log(`  ❌ ${label}\n     ${error.message}`)
	}
}

console.log('\n── 导出形状 ──')
check('name 是 dsh-notify-desktop', () => assert.equal(mod.name, 'dsh-notify-desktop'))
check('inject 含 webServer', () => assert.deepEqual(mod.inject, ['webServer']))
check('有 Config（schemastery schema）', () => assert.equal(typeof mod.Config, 'function'))
check('有 apply', () => assert.equal(typeof mod.apply, 'function'))
check('没有 default export（有的话 Loader 会丢掉 inject）', () => assert.equal(mod.default, undefined))

console.log('\n── 桩 ctx ──')
const routes = new Map()
const handlers = { session: [], dispose: [] }
const ctx = {
	logger: () => ({ info() {}, warn() {}, error() {} }),
	on(name, fn) { (handlers[name] ??= []).push(fn) },
	effect(fn) { handlers.dispose.push(fn()) },
	get(name) {
		if (name === 'sessionTitle') return { get: (s) => ({ title: `标题-${String(s.id).slice(0, 4)}` }) }
		if (name === 'agents') return { get: () => undefined }
		return undefined
	},
	webServer: {
		port: 3080,
		register(route) { routes.set(route.path, route); return () => routes.delete(route.path) },
	},
}

// reasons 只留一个不会命中的值 → 整轮测试都不会真的起卡片
const config = mod.Config({ reasons: ['never-matches'] })
mod.apply(ctx, config)

console.log('\n── 路由注册 ──')
check('注册了 clickPath', () => assert.ok(routes.has('/dsh-notify/click')))
check('注册了 pendingPath', () => assert.ok(routes.has('/dsh-notify/pending')))
check('两个都是 exact 路由', () => {
	assert.equal(routes.get('/dsh-notify/click').kind, 'exact')
	assert.equal(routes.get('/dsh-notify/pending').kind, 'exact')
})
check('订阅了 session/event', () => assert.equal(handlers['session/event'].length, 1))

console.log('\n── 事件过滤（都不该起卡片）──')
const fire = (session, event) => handlers['session/event'][0](session, event)
check('非 turn/end 事件被忽略', () => {
	fire({ id: 's1', header: {} }, { type: 'step/end', data: {} })
})
check('子代理会话被跳过', () => {
	fire({ id: 's2', header: { origin: 'subagent' } }, { type: 'turn/end', data: { reason: { kind: 'completed' } } })
})
check('delegationDepth > 0 被跳过', () => {
	fire({ id: 's3', header: { delegationDepth: 2 } }, { type: 'turn/end', data: { reason: { kind: 'completed' } } })
})
check('reasons 白名单外的原因被过滤', () => {
	fire({ id: 's4', header: {} }, { type: 'turn/end', data: { reason: { kind: 'completed' } } })
})
check('disposed 导致的 aborted 被忽略', () => {
	fire({ id: 's5', header: {} }, { type: 'turn/end', data: { reason: { kind: 'aborted', reason: { kind: 'disposed' } } } })
})

console.log('\n── 点击回调 ↔ 轮询（单消费者）──')
function fakeRes() {
	const res = { status: 0, headers: null, body: '' }
	res.writeHead = (status, headers) => { res.status = status; res.headers = headers }
	res.end = (body) => { res.body = body ?? '' }
	return res
}
const sessionId = 'abc12345-6789-4def-9012-3456789abcde'
check('点击端点返回 200 并记录会话', () => {
	const res = fakeRes()
	routes.get('/dsh-notify/click').handler({ url: `/dsh-notify/click?session=${sessionId}` }, res)
	assert.equal(res.status, 200)
})
check('轮询端点返回该会话', () => {
	const res = fakeRes()
	routes.get('/dsh-notify/pending').handler({ url: '/dsh-notify/pending' }, res)
	assert.equal(JSON.parse(res.body).sessionId, sessionId)
})
check('再轮询一次已被消费（单消费者）', () => {
	const res = fakeRes()
	routes.get('/dsh-notify/pending').handler({ url: '/dsh-notify/pending' }, res)
	assert.equal(JSON.parse(res.body).sessionId, null)
})
check('缺 session 参数返回 400', () => {
	const res = fakeRes()
	routes.get('/dsh-notify/click').handler({ url: '/dsh-notify/click' }, res)
	assert.equal(res.status, 400)
})

console.log(`\n${fail === 0 ? '✅ 全部通过' : '❌ 有失败'}：${pass} 通过 / ${fail} 失败\n`)
process.exit(fail === 0 ? 0 : 1)
