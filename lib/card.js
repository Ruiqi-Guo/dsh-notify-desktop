/**
 * 卡片呈现层：把「某个会话完成了」变成屏幕上那张橙色常驻卡片。
 *
 * 刻意做成**不依赖 DSH 任何 API** 的独立模块 —— 只有 Node 内置模块 + 一个
 * PowerShell 脚本，所以它可以脱离 DSH 单独测试，也方便别人复用。
 *
 * 为什么卡片要另起进程：Cordis 插件跑在 DSH 的 Node 进程里，画不了 WinForms 窗口；
 * 而且卡片需要阻塞到用户点击，绝不能把 agent 的收尾卡住 —— 所以分离启动、立即返回。
 *
 * @module dsh-notify-desktop/card
 */

import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

/** 包内自带的卡片脚本。 */
export const BUNDLED_CARD = join(HERE, '..', 'assets', 'dsh-notify.ps1')

/**
 * 决定用哪个卡片脚本：配置里指定且存在就用它，否则用包内自带的。
 * @param configured - 配置项 `cardScript`，可为空。
 * @returns 脚本绝对路径；两者都不存在时返回 null。
 */
export function resolveCardScript(configured) {
	if (configured && existsSync(configured)) return configured
	return existsSync(BUNDLED_CARD) ? BUNDLED_CARD : null
}

/**
 * 弹一张卡片（不阻塞调用方）。
 *
 * 🔴 两个实测结论决定了这里的实现，改动前请先看 `docs/spawn-probe.md`：
 *
 * 1. **不能直接 `spawn('powershell.exe', …)`** —— 进程会正常起来、`Application.Run`
 *    也在跑，但**屏幕上不会出现任何窗口**（连隐藏窗口都没有），而且没有任何报错。
 *    唯一能从 Node 拉起可见窗口的路径是经 `cmd /c start`。
 * 2. **中文不能走命令行参数** —— 参数要经过 `cmd.exe`，而它按 OEM 代码页解释 argv，
 *    中文会话名会变乱码。所以内容一律写进 UTF-8 的 JSON 临时文件，
 *    命令行上只留纯 ASCII 的路径。
 *
 * @param options - 卡片内容与行为。
 * @returns `{ ok, pid }` 或 `{ ok: false, error }`。
 */
export function showCard(options) {
	const {
		script,
		title,
		session,
		message,
		tag,
		accent,
		persist,
		onClick,
		onClickUrl,
		seconds,
	} = options ?? {}

	if (!script) return { ok: false, error: 'card script not found' }
	if (!existsSync(script)) return { ok: false, error: `card script missing: ${script}` }

	// 卡片内容走 UTF-8 JSON：避开 cmd.exe 的代码页问题
	const payload = {
		title,
		session,
		message,
		tag,
		accent,
		onClick,
		onClickUrl,
		seconds: seconds ?? (persist === false ? 10 : 0),
	}

	try {
		const dir = mkdtempSync(join(tmpdir(), 'dsh-notify-'))
		const jsonPath = join(dir, 'card.json')
		writeFileSync(jsonPath, JSON.stringify(payload), 'utf8')

		const child = spawn(
			'cmd.exe',
			[
				'/c', 'start', '', '/b',
				'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
				'-File', script, '-FromJson', jsonPath,
			],
			{ stdio: 'ignore', windowsHide: true },
		)
		child.unref()
		return { ok: true, pid: child.pid, payload: jsonPath }
	} catch (error) {
		return { ok: false, error: error instanceof Error ? error.message : String(error) }
	}
}
