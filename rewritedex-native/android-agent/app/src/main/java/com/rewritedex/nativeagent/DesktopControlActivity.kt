package com.rewritedex.nativeagent

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

class DesktopControlActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.rgb(18, 20, 22)
        window.navigationBarColor = Color.rgb(18, 20, 22)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
            setBackgroundColor(Color.rgb(18, 20, 22))
        }

        // Polished header
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(16))
        }
        header.addView(TextView(this).apply {
            text = "RewriteDEX"
            textSize = 22f
            setTextColor(Color.rgb(138, 180, 248)) // accent blue
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        header.addView(TextView(this).apply {
            text = "  •  Phone Control"
            textSize = 16f
            setTextColor(Color.rgb(154, 160, 166))
        })
        root.addView(header)

        // Trackpad hint
        root.addView(TextView(this).apply {
            text = "Trackpad • Tap to click • Two-finger scroll"
            textSize = 12f
            setTextColor(Color.rgb(154, 160, 166))
            setPadding(0, 0, 0, dp(8))
        })

        root.addView(TrackpadView(), LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            0,
            1f,
        ))

        val textRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(12), 0, dp(8))
        }
        val input = EditText(this).apply {
            hint = "Type on desktop"
            setTextColor(Color.WHITE)
            setHintTextColor(Color.rgb(160, 166, 172))
            setSingleLine(true)
            setBackgroundColor(Color.rgb(38, 42, 46))
            setPadding(dp(14), dp(4), dp(14), dp(4))
            // Rounded feel hint (via background drawable could be added)
        }
        textRow.addView(input, LinearLayout.LayoutParams(0, dp(48), 1f))
        textRow.addView(actionButton("Send") {
            input.text?.toString()?.takeIf { it.isNotEmpty() }?.let { value ->
                sendControl("text", text = value)
                input.text.clear()
            }
        }, LinearLayout.LayoutParams(dp(82), dp(48)).apply { marginStart = dp(8) })
        root.addView(textRow)

        val nav = LinearLayout(this).apply { gravity = Gravity.CENTER }
        listOf(
            "Back" to "back",
            "Home" to "home",
            "Recents" to "recents",
            "Keyboard" to "keyboard",
        ).forEach { (label, action) ->
            nav.addView(actionButton(label) { sendControl(action) }, LinearLayout.LayoutParams(0, dp(48), 1f).apply {
                marginStart = dp(3)
                marginEnd = dp(3)
            })
        }
        root.addView(nav)
        val tools = LinearLayout(this).apply { gravity = Gravity.CENTER }
        listOf(
            "Previous" to "presentation-previous",
            "Play/Pause" to "media-play-pause",
            "Next" to "presentation-next",
            "Workspace" to "workspace-next",
        ).forEach { (label, action) ->
            tools.addView(actionButton(label) { sendControl(action) }, LinearLayout.LayoutParams(0, dp(44), 1f).apply {
                marginStart = dp(3)
                marginEnd = dp(3)
            })
        }
        root.addView(tools)
        setContentView(root)
    }

    private fun actionButton(label: String, action: () -> Unit): Button = Button(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = 13f
        setBackgroundColor(Color.rgb(42, 48, 54))
        setPadding(dp(12), dp(6), dp(12), dp(6))
        setOnClickListener { action() }
    }

    private fun sendControl(action: String, x: Float = 0f, y: Float = 0f, delta: Float = 0f, text: String? = null) {
        val intent = Intent(this, DexAgentService::class.java)
            .setAction(DexAgentService.ACTION_PHONE_CONTROL)
            .putExtra("control", action)
            .putExtra("x", x)
            .putExtra("y", y)
            .putExtra("delta", delta)
        if (text != null) intent.putExtra("text", text)
        startForegroundService(intent)
    }

    private inner class TrackpadView : View(this) {
        private var downAt = 0L
        private var downX = 0f
        private var downY = 0f
        private var lastSentAt = 0L
        private var lastTwoFingerY = 0f

        init {
            // Polished trackpad with subtle border feel
            setBackgroundColor(Color.rgb(28, 32, 36))
            contentDescription = "Desktop trackpad — drag to move cursor, tap to click, two fingers to scroll"
            // Add a subtle border via background (simple solid for now)
        }

        override fun onDraw(canvas: android.graphics.Canvas) {
            super.onDraw(canvas)
            // Subtle inner border for DeX polish
            val paint = android.graphics.Paint().apply {
                color = Color.rgb(58, 64, 72)
                style = android.graphics.Paint.Style.STROKE
                strokeWidth = dp(2).toFloat()
            }
            canvas.drawRoundRect(4f, 4f, (width - 4).toFloat(), (height - 4).toFloat(), dp(12).toFloat(), dp(12).toFloat(), paint)
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            val x = (event.x / width.coerceAtLeast(1)).coerceIn(0f, 1f)
            val y = (event.y / height.coerceAtLeast(1)).coerceIn(0f, 1f)
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downAt = SystemClock.uptimeMillis()
                    downX = event.x
                    downY = event.y
                    lastTwoFingerY = event.y
                    sendControl("move", x, y)
                }
                MotionEvent.ACTION_POINTER_DOWN -> lastTwoFingerY = event.getY(0)
                MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount >= 2) {
                        val currentY = event.getY(0)
                        val delta = ((lastTwoFingerY - currentY) / dp(20)).coerceIn(-5f, 5f)
                        if (kotlin.math.abs(delta) >= 0.2f) {
                            sendControl("scroll", x, y, delta)
                            lastTwoFingerY = currentY
                        }
                    } else if (SystemClock.uptimeMillis() - lastSentAt >= 32) {
                        sendControl("move", x, y)
                        lastSentAt = SystemClock.uptimeMillis()
                    }
                }
                MotionEvent.ACTION_UP -> {
                    val distance = kotlin.math.hypot(event.x - downX, event.y - downY)
                    if (SystemClock.uptimeMillis() - downAt < 280 && distance < dp(12)) {
                        sendControl("click", x, y)
                        performClick()
                    }
                }
            }
            return true
        }

        override fun performClick(): Boolean = super.performClick()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
