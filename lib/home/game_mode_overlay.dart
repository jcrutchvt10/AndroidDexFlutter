import 'package:flutter/material.dart';

import '../core/game_profile.dart';

/// Overlay widget that renders a gaming-mode control panel over the desktop.
///
/// Shows a D-pad, virtual joystick, action buttons, and a tap-spot toggle
/// when game mode is active for the focused Android app window.
///
/// Profiles are loaded from [GameProfileStore] and matched to the focused
/// window's package name. The overlay only renders when game mode is enabled
/// and a profile is available.
///
/// Note: actual input injection into the device is performed by the JAR/ADB
/// commands wired elsewhere; this widget is purely visual and captures
/// pointer input to feed into the input dispatcher.
class GameModeOverlay extends StatefulWidget {
  const GameModeOverlay({
    super.key,
    required this.core,
    required this.store,
    required this.activePackage,
    required this.enabled,
    required this.onInput,
  });

  final dynamic core;
  final GameProfileStore store;
  final String? activePackage;
  final bool enabled;
  final void Function(String action, {double? x, double? y}) onInput;

  @override
  State<GameModeOverlay> createState() => _GameModeOverlayState();
}

class _GameModeOverlayState extends State<GameModeOverlay> {
  GameProfile? _profile;

  @override
  void didUpdateWidget(GameModeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _profile = widget.store.profileForPackage(widget.activePackage ?? '');
  }

  @override
  void initState() {
    super.initState();
    _profile = widget.store.profileForPackage(widget.activePackage ?? '');
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _profile == null) {
      return const SizedBox.shrink();
    }

    final profile = _profile!;
    final desktop = MediaQuery.sizeOf(context);

    // Profile coordinates are Android virtual-display points (1280x720 by
    // default); scale them onto whatever the desktop is currently sized at so
    // portrait-phone-era profiles stay on-screen instead of drifting off it.
    Offset toLocal(Offset devicePoint) => Offset(
      (devicePoint.dx / 1280 * desktop.width).clamp(0.0, desktop.width),
      (devicePoint.dy / 720 * desktop.height).clamp(0.0, desktop.height),
    );

    return Stack(
      children: [
        // D-Pad
        _DpadWidget(
          center: toLocal(profile.dpadCenter),
          buttonRadius: profile.dpadButtonRadius,
          onTap: (direction) {
            widget.onInput('dpad_${direction.toLowerCase()}');
          },
        ),

        // Virtual Joystick
        if (profile.joystickRadius > 0)
          _JoystickWidget(
            center: toLocal(profile.joystickCenter),
            radius: profile.joystickRadius,
            onMove: (dx, dy) {
              widget.onInput('joystick', x: dx, y: dy);
            },
            onRelease: () => widget.onInput('joystick_release'),
          ),

        // Action Buttons
        ...profile.actionButtons.map((button) {
          return _ActionButtonWidget(
            key: ValueKey(button.label),
            label: button.label,
            position: toLocal(Offset(button.deviceX, button.deviceY)),
            onTap: () => widget.onInput('button_${button.label.toLowerCase()}'),
          );
        }),

        // Tap Spot toggle (shown as a small button near the top)
        if (profile.tapSpotEnabled)
          _TapSpotToggle(
            enabled: profile.tapSpotEnabled,
            turbo: profile.tapSpotTurbo,
            onToggle: (enabled) {
              widget.onInput('tapspot_toggle', x: enabled ? 1 : 0);
            },
            onTurbo: (turbo) {
              widget.onInput('tapspot_turbo', x: turbo ? 1 : 0);
            },
          ),
      ],
    );
  }
}

class _DpadWidget extends StatelessWidget {
  const _DpadWidget({
    required this.center,
    required this.buttonRadius,
    required this.onTap,
  });

  final Offset center;
  final double buttonRadius;
  final void Function(String direction) onTap;

  @override
  Widget build(BuildContext context) {
    final bg = _button('center', center, buttonRadius * 0.5);
    final up = _button(
      'up',
      Offset(center.dx, center.dy - buttonRadius * 1.6),
      buttonRadius,
    );
    final down = _button(
      'down',
      Offset(center.dx, center.dy + buttonRadius * 1.6),
      buttonRadius,
    );
    final left = _button(
      'left',
      Offset(center.dx - buttonRadius * 1.6, center.dy),
      buttonRadius,
    );
    final right = _button(
      'right',
      Offset(center.dx + buttonRadius * 1.6, center.dy),
      buttonRadius,
    );

    return Positioned(
      left: center.dx - buttonRadius * 2.2,
      top: center.dy - buttonRadius * 2.2,
      child: Stack(children: [bg, up, down, left, right]),
    );
  }

  Widget _button(String direction, Offset pos, double radius) {
    return Positioned(
      left: pos.dx - radius,
      top: pos.dy - radius,
      child: GestureDetector(
        onTap: () => onTap(direction),
        child: Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            color: const Color(0xFF2A3A4A),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: const Color(0xFF4A5A6A), width: 2),
          ),
          child: Center(
            child: Icon(
              _iconFor(direction),
              size: radius * 0.6,
              color: const Color(0xFF8A9AAA),
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String dir) {
    return switch (dir) {
      'up' => Icons.arrow_upward,
      'down' => Icons.arrow_downward,
      'left' => Icons.arrow_back,
      'right' => Icons.arrow_forward,
      _ => Icons.circle,
    };
  }
}

class _JoystickWidget extends StatefulWidget {
  const _JoystickWidget({
    required this.center,
    required this.radius,
    required this.onMove,
    required this.onRelease,
  });

  final Offset center;
  final double radius;
  final void Function(double dx, double dy) onMove;
  final VoidCallback onRelease;

  @override
  State<_JoystickWidget> createState() => _JoystickWidgetState();
}

class _JoystickWidgetState extends State<_JoystickWidget> {
  Offset _stickOffset = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.center.dx - widget.radius,
      top: widget.center.dy - widget.radius,
      child: GestureDetector(
        onPanStart: (_) => _handleMove(Offset.zero),
        onPanUpdate: (event) => _handleMove(event.delta),
        onPanEnd: (_) {
          setState(() => _stickOffset = Offset.zero);
          widget.onRelease();
        },
        child: Stack(
          children: [
            // Base circle
            Container(
              width: widget.radius * 2,
              height: widget.radius * 2,
              decoration: BoxDecoration(
                color: const Color(0xFF1A2A3A),
                borderRadius: BorderRadius.circular(widget.radius),
                border: Border.all(color: const Color(0xFF4A5A6A), width: 2),
              ),
            ),
            // Sticks
            Positioned(
              left: widget.radius + _stickOffset.dx - 16,
              top: widget.radius + _stickOffset.dy - 16,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF8A9AAA),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleMove(Offset delta) {
    final maxDist = widget.radius - 16;
    final dist = delta.distance;
    final clamped = dist > maxDist ? delta * (maxDist / dist) : delta;
    setState(() => _stickOffset = clamped);
    final normalizedDx = clamped.dx / maxDist;
    final normalizedDy = clamped.dy / maxDist;
    widget.onMove(normalizedDx, normalizedDy);
  }
}

class _ActionButtonWidget extends StatelessWidget {
  const _ActionButtonWidget({
    super.key,
    required this.label,
    required this.position,
    required this.onTap,
  });

  final String label;
  final Offset position;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isPrimary = label == 'A' || label == 'B';
    final size = isPrimary ? 56.0 : 44.0;

    return Positioned(
      left: position.dx - size / 2,
      top: position.dy - size / 2,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: isPrimary
                ? const Color(0xFF3A5A8A)
                : const Color(0xFF4A3A5A),
            borderRadius: BorderRadius.circular(size / 2),
            border: Border.all(
              color: isPrimary
                  ? const Color(0xFF6A8ABA)
                  : const Color(0xFF6A5A8A),
              width: 2,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: isPrimary ? 20 : 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TapSpotToggle extends StatelessWidget {
  const _TapSpotToggle({
    required this.enabled,
    required this.turbo,
    required this.onToggle,
    required this.onTurbo,
  });

  final bool enabled;
  final bool turbo;
  final ValueChanged<bool> onToggle;
  final ValueChanged<bool> onTurbo;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 40,
      top: 20,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF2A3A4A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: enabled
                    ? const Color(0xFF6A5ABA)
                    : const Color(0xFF4A5A6A),
                width: 2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.touch_app,
                  size: 16,
                  color: enabled ? Colors.white : const Color(0xFF6A7A8A),
                ),
                const SizedBox(width: 6),
                Text(
                  'Tap Spot',
                  style: TextStyle(
                    color: enabled ? Colors.white : const Color(0xFF6A7A8A),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Switch(
                  value: enabled,
                  onChanged: onToggle,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Material(
                color: const Color(0xFF2A3A4A),
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onTurbo(!turbo),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.speed,
                          size: 14,
                          color: turbo ? Colors.amber : const Color(0xFF6A7A8A),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          turbo ? 'Turbo ON' : 'Turbo OFF',
                          style: TextStyle(
                            color: turbo
                                ? Colors.amber
                                : const Color(0xFF6A7A8A),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
