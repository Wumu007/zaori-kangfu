package com.medreminder.med_reminder

import android.content.Context
import android.os.Environment
import java.io.File

/**
 * 数据保险箱（V1.15.0）
 *
 * ═══════════════════════════════════════════════════════════════════
 * 为什么需要它（用户第 8 份日志 + 反复重装的体验）
 * ═══════════════════════════════════════════════════════════════════
 *
 * 日志原文：
 *   [PERM]   权限快照 | 通知=false 精确闹钟=true 电池白名单=false
 *   [NOTIFY] 排程汇总 | 成功 0 条 / 失败 0 条 / 在提醒 0 种药
 *
 * 「在提醒 0 种药」是根因 —— 重装后本地数据库被清空，App 里一种药都没有，
 * 排程自然是 0 条。这不是通知坏了，是**没有东西可以提醒**。
 * 用户还提到「每次重装都要重新填腾讯云密钥」，同一类问题：
 * App 的所有数据（药品、记录、设置、密钥）都只存在应用私有目录里，
 * 卸载即删。
 *
 * 系统级的 Auto Backup 在国产 ROM + 侧载安装上基本不生效，所以这里
 * 自己写一份到 **Android/media/<包名>/**：
 *
 * - 该目录在 Android 11+ 属于「媒体目录」，应用可以读写自己包名下的
 *   子目录，**不需要任何存储权限**；
 * - 卸载 App **不会**删除它（系统把它当作用户的媒体文件），
 *   重装后仍在，正好用来恢复；
 * - 用户也能在「文件管理 → Android/media → 包名」里看到、手动删掉。
 *
 * 隐私说明：文件里含腾讯云密钥，明文落在上述目录。这对单机自用是可接受
 * 的取舍（不这么做就只能每次重填），设置页的说明文字里已如实告知，
 * 并提供「清除保险箱」入口。
 */
object VaultStore {

    private const val FILE_NAME = "zaori-vault.json"
    private const val DIR_NAME = "Android/media"

    /**
     * 保险箱文件路径。
     *
     * 优先放到 Android/media/<包名>/（卸载不删）；极端情况下
     * （ROM 不允许写外部存储）退到应用私有目录 —— 那时重装会丢，
     * 但至少不会崩。
     */
    fun file(context: Context): File {
        // 1) 首选：Android/media/<包名>/
        try {
            val ext = Environment.getExternalStorageDirectory()
            val dir = File(File(ext, DIR_NAME), context.packageName)
            if (!dir.exists() && !dir.mkdirs()) {
                // mkdirs 失败（没挂载/权限问题）→ 走兜底
            } else {
                return File(dir, FILE_NAME)
            }
        } catch (_: Exception) {}

        // 2) 兜底：应用外部专属目录（卸载会删，但总比没有强）
        try {
            val dir = context.getExternalFilesDir(null)
            if (dir != null) return File(dir, FILE_NAME)
        } catch (_: Exception) {}

        // 3) 最后兜底：应用内部目录
        return File(context.filesDir, FILE_NAME)
    }

    /**
     * 写入保险箱。返回写入的绝对路径（失败返回 null）。
     *
     * 用「先写临时文件再 rename」：中途被杀不会留下半截 JSON，
     * 否则下次启动恢复时会解析失败，比没备份更糟。
     */
    @JvmStatic
    fun save(context: Context, json: String): String? {
        return try {
            val target = file(context)
            target.parentFile?.mkdirs()
            val tmp = File(target.parentFile, "$FILE_NAME.tmp")
            tmp.writeText(json)
            if (target.exists()) target.delete()
            val ok = tmp.renameTo(target)
            if (!ok) {
                target.writeText(json)
                tmp.delete()
            }
            NativeLog.log("Vault", "已备份 ${json.length} 字节 → ${target.absolutePath}")
            target.absolutePath
        } catch (e: Exception) {
            NativeLog.log("Vault", "备份失败: ${e.javaClass.simpleName} ${e.message}")
            null
        }
    }

    /** 读取保险箱内容；没有文件时返回 null */
    @JvmStatic
    fun load(context: Context): String? {
        return try {
            val f = file(context)
            if (!f.exists() || f.length() <= 0L) null else f.readText()
        } catch (e: Exception) {
            NativeLog.log("Vault", "读取失败: ${e.message}")
            null
        }
    }

    /** 保险箱文件的绝对路径（设置页展示用；没有文件也返回预期路径） */
    @JvmStatic
    fun path(context: Context): String = file(context).absolutePath

    /** 是否已有备份 */
    @JvmStatic
    fun exists(context: Context): Boolean {
        return try {
            file(context).exists()
        } catch (_: Exception) {
            false
        }
    }

    /** 删除保险箱（用户在设置页主动清理） */
    @JvmStatic
    fun clear(context: Context): Boolean {
        return try {
            val f = file(context)
            if (f.exists()) f.delete() else true
        } catch (_: Exception) {
            false
        }
    }
}
