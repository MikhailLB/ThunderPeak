import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

enum EnemyKind { harpy, cyclops, medusa, minotaur }

class Enemy {
  Enemy({
    required this.kind,
    required this.pos,
    required this.hp,
    required this.maxHp,
    required this.speed,
    required this.reward,
    required this.size,
  });

  final EnemyKind kind;
  Offset pos;
  double hp;
  final double maxHp;
  final double speed;
  final int reward;
  final double size;
  double flashTimer = 0.0;
}

class LightningBolt {
  LightningBolt({
    required this.start,
    required this.end,
    required this.width,
    required this.power,
  });

  final Offset start;
  final Offset end;
  final double width;
  final double power;
  double life = 0.35;
}

class Particle {
  Particle({
    required this.pos,
    required this.vel,
    required this.color,
    required this.size,
    required this.life,
  });

  Offset pos;
  Offset vel;
  Color color;
  double size;
  double life;
  final double maxLife = 0.8;
}

class Collectible {
  Collectible({
    required this.pos,
    required this.kind,
  });

  Offset pos;
  final String kind;
  double life = 6.0;
  double phase = 0.0;
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  final math.Random _rng = math.Random();

  Size _screen = Size.zero;
  Offset _zeus = Offset.zero;

  final List<Enemy> _enemies = [];
  final List<LightningBolt> _bolts = [];
  final List<Particle> _particles = [];
  final List<Collectible> _collectibles = [];

  // Charge state.
  bool _charging = false;
  Offset _aim = Offset.zero;
  double _charge = 0.0; // 0..1

  // Progression / stats.
  int _score = 0;
  int _energy = 0;
  int _kills = 0;
  double _time = 0.0;
  double _spawnTimer = 0.0;
  double _spawnInterval = 1.2;
  bool _gameOver = false;
  bool _paused = false;

  // Powerups.
  double _shieldTime = 0.0;
  double _stormRageTime = 0.0;

  // Upgrades (from energy).
  int _powerLevel = 0; // increases damage
  int _speedLevel = 0; // faster charge

  static const double _zeusRadius = 42.0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (_lastTick == Duration.zero) {
      _lastTick = elapsed;
      return;
    }
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (_paused || _gameOver || _screen == Size.zero) {
      setState(() {});
      return;
    }
    _update(dt.clamp(0.0, 0.05));
    setState(() {});
  }

  void _update(double dt) {
    _time += dt;

    // Difficulty ramps.
    _spawnInterval = math.max(0.35, 1.2 - _time * 0.012);
    _spawnTimer -= dt;
    if (_spawnTimer <= 0) {
      _spawnTimer = _spawnInterval;
      _spawnEnemy();
    }

    // Charging.
    if (_charging) {
      final chargeRate = 0.55 + 0.15 * _speedLevel;
      _charge = (_charge + dt * chargeRate).clamp(0.0, 1.0);
    }

    // Update powerups timers.
    if (_shieldTime > 0) _shieldTime -= dt;
    if (_stormRageTime > 0) {
      _stormRageTime -= dt;
      // Storm rage: auto-strike closest enemy periodically.
      if ((_time * 4).floor() != ((_time - dt) * 4).floor()) {
        _autoStrike();
      }
    }

    // Move enemies.
    for (final e in _enemies) {
      final dir = (_zeus - e.pos);
      final dist = dir.distance;
      if (dist > 0.001) {
        final v = dir / dist * e.speed * dt;
        e.pos = e.pos + v;
      }
      if (e.flashTimer > 0) e.flashTimer -= dt;
    }

    // Check enemies reaching Zeus.
    final reached = <Enemy>[];
    for (final e in _enemies) {
      if ((_zeus - e.pos).distance < _zeusRadius + e.size * 0.35) {
        reached.add(e);
      }
    }
    for (final e in reached) {
      _enemies.remove(e);
      if (_shieldTime > 0) {
        _spawnParticles(e.pos, const Color(0xFF66E1FF), 20);
      } else {
        _gameOver = true;
        _spawnParticles(_zeus, const Color(0xFFFFC93A), 40);
      }
    }

    // Bolts life.
    for (final b in _bolts) {
      b.life -= dt;
    }
    _bolts.removeWhere((b) => b.life <= 0);

    // Particles.
    for (final p in _particles) {
      p.pos = p.pos + p.vel * dt;
      p.vel = p.vel * 0.94;
      p.life -= dt;
    }
    _particles.removeWhere((p) => p.life <= 0);

    // Collectibles.
    for (final c in _collectibles) {
      c.life -= dt;
      c.phase += dt;
    }
    _collectibles.removeWhere((c) {
      if (c.life <= 0) return true;
      if ((c.pos - _zeus).distance < _zeusRadius + 30) {
        _applyCollectible(c);
        return true;
      }
      return false;
    });
  }

  void _spawnEnemy() {
    // Choose spawn side: from an edge, moving to center.
    final w = _screen.width;
    final h = _screen.height;
    final edge = _rng.nextInt(4);
    Offset pos;
    switch (edge) {
      case 0:
        pos = Offset(_rng.nextDouble() * w, -40);
        break;
      case 1:
        pos = Offset(w + 40, _rng.nextDouble() * h * 0.7);
        break;
      case 2:
        pos = Offset(_rng.nextDouble() * w, h + 40);
        break;
      default:
        pos = Offset(-40, _rng.nextDouble() * h * 0.7);
    }

    // Weighted kind selection based on time.
    final t = _time;
    final kinds = <EnemyKind>[];
    kinds.addAll(List.filled(6, EnemyKind.harpy));
    if (t > 8) kinds.addAll(List.filled(4, EnemyKind.cyclops));
    if (t > 18) kinds.addAll(List.filled(3, EnemyKind.medusa));
    if (t > 30) kinds.addAll(List.filled(3, EnemyKind.minotaur));
    final kind = kinds[_rng.nextInt(kinds.length)];

    late double hp, speed, size;
    late int reward;
    switch (kind) {
      case EnemyKind.harpy:
        hp = 1;
        speed = 60 + _time * 0.4;
        size = 70;
        reward = 5;
        break;
      case EnemyKind.cyclops:
        hp = 3;
        speed = 42 + _time * 0.25;
        size = 90;
        reward = 12;
        break;
      case EnemyKind.medusa:
        hp = 4;
        speed = 55 + _time * 0.3;
        size = 82;
        reward = 18;
        break;
      case EnemyKind.minotaur:
        hp = 6;
        speed = 48 + _time * 0.28;
        size = 96;
        reward = 25;
        break;
    }

    _enemies.add(Enemy(
      kind: kind,
      pos: pos,
      hp: hp,
      maxHp: hp,
      speed: speed,
      reward: reward,
      size: size,
    ));
  }

  void _spawnCollectible(Offset pos) {
    // Random chance to drop something.
    final r = _rng.nextDouble();
    String kind;
    if (r < 0.55) {
      kind = 'coin';
    } else if (r < 0.78) {
      kind = 'lightning';
    } else if (r < 0.9) {
      kind = 'ambrosia';
    } else if (r < 0.96) {
      kind = 'shield';
    } else {
      kind = 'storm';
    }
    _collectibles.add(Collectible(pos: pos, kind: kind));
  }

  void _applyCollectible(Collectible c) {
    switch (c.kind) {
      case 'coin':
        _energy += 10;
        _score += 15;
        break;
      case 'lightning':
        _charge = 1.0;
        _energy += 3;
        break;
      case 'ambrosia':
        _energy += 20;
        _score += 20;
        break;
      case 'shield':
        _shieldTime = 6.0;
        break;
      case 'storm':
        _stormRageTime = 5.0;
        break;
    }
    _spawnParticles(c.pos, const Color(0xFFFFD84D), 14);
  }

  void _autoStrike() {
    if (_enemies.isEmpty) return;
    Enemy? nearest;
    double best = double.infinity;
    for (final e in _enemies) {
      final d = (e.pos - _zeus).distance;
      if (d < best) {
        best = d;
        nearest = e;
      }
    }
    if (nearest == null) return;
    _fireLightning(nearest.pos, power: 0.6);
  }

  void _fireLightning(Offset target, {double? power}) {
    final p = power ?? _charge;
    final baseDamage = 0.9 + p * 3.2 + _powerLevel * 0.6;
    final radius = 40 + p * 60.0;

    _bolts.add(LightningBolt(
      start: _zeus,
      end: target,
      width: 2 + p * 6,
      power: p,
    ));

    // Damage enemies within radius of impact.
    final hits = <Enemy>[];
    for (final e in List<Enemy>.from(_enemies)) {
      final d = (e.pos - target).distance;
      if (d < radius + e.size * 0.3) {
        e.hp -= baseDamage;
        e.flashTimer = 0.15;
        hits.add(e);
      }
    }

    _spawnParticles(target, const Color(0xFF66E1FF), (10 + p * 30).round());

    for (final e in hits) {
      if (e.hp <= 0) {
        _enemies.remove(e);
        _kills++;
        _score += e.reward;
        _energy += (e.reward * 0.4).round();
        _spawnParticles(e.pos, const Color(0xFFFFC93A), 18);
        if (_rng.nextDouble() < 0.22) {
          _spawnCollectible(e.pos);
        }
      }
    }
  }

  void _spawnParticles(Offset pos, Color color, int count) {
    for (int i = 0; i < count; i++) {
      final a = _rng.nextDouble() * math.pi * 2;
      final s = 60 + _rng.nextDouble() * 220;
      _particles.add(Particle(
        pos: pos,
        vel: Offset(math.cos(a), math.sin(a)) * s,
        color: color,
        size: 2 + _rng.nextDouble() * 4,
        life: 0.4 + _rng.nextDouble() * 0.4,
      ));
    }
  }

  // Upgrade functions.
  void _upgradePower() {
    final cost = 40 + _powerLevel * 30;
    if (_energy >= cost) {
      setState(() {
        _energy -= cost;
        _powerLevel++;
      });
    }
  }

  void _upgradeSpeed() {
    final cost = 40 + _speedLevel * 30;
    if (_energy >= cost) {
      setState(() {
        _energy -= cost;
        _speedLevel++;
      });
    }
  }

  /// Returns true if a tap at [pos] picked up a collectible.
  /// The closest collectible within a finger-friendly radius is preferred.
  bool _tryTapCollectible(Offset pos) {
    const double tapRadius = 44.0;
    Collectible? target;
    double bestDist = double.infinity;
    for (final c in _collectibles) {
      final d = (c.pos - pos).distance;
      if (d < tapRadius && d < bestDist) {
        bestDist = d;
        target = c;
      }
    }
    if (target == null) return false;
    _applyCollectible(target);
    _collectibles.remove(target);
    return true;
  }

  void _restart() {
    setState(() {
      _enemies.clear();
      _bolts.clear();
      _particles.clear();
      _collectibles.clear();
      _score = 0;
      _energy = 0;
      _kills = 0;
      _time = 0;
      _spawnTimer = 0;
      _spawnInterval = 1.2;
      _gameOver = false;
      _paused = false;
      _shieldTime = 0;
      _stormRageTime = 0;
      _powerLevel = 0;
      _speedLevel = 0;
      _charge = 0;
      _charging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          _screen = Size(constraints.maxWidth, constraints.maxHeight);
          _zeus = Offset(_screen.width / 2, _screen.height * 0.68);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) {
              if (_gameOver || _paused) return;
              if (_tryTapCollectible(d.localPosition)) {
                setState(() {});
                return;
              }
              setState(() {
                _charging = true;
                _charge = 0.0;
                _aim = d.localPosition;
              });
            },
            onPanUpdate: (d) {
              if (_gameOver || _paused) return;
              if (!_charging) return;
              setState(() {
                _aim = d.localPosition;
              });
            },
            onPanEnd: (d) {
              if (_gameOver || _paused) return;
              if (_charging) {
                _fireLightning(_aim);
              }
              setState(() {
                _charging = false;
                _charge = 0.0;
              });
            },
            onTapDown: (d) {
              if (_gameOver || _paused) return;
              if (_tryTapCollectible(d.localPosition)) {
                setState(() {});
                return;
              }
              setState(() {
                _charging = true;
                _charge = 0.0;
                _aim = d.localPosition;
              });
            },
            onTapUp: (d) {
              if (_gameOver || _paused) return;
              if (_charging) {
                _fireLightning(_aim);
              }
              setState(() {
                _charging = false;
                _charge = 0.0;
              });
            },
            onTapCancel: () {
              if (!_charging) return;
              setState(() {
                _charging = false;
                _charge = 0.0;
              });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Background.
                Image.asset(
                  'assets/Background_ThunderPeak.webp',
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.25),
                        Colors.transparent,
                        Colors.black.withOpacity(0.45),
                      ],
                    ),
                  ),
                ),

                // Game canvas painter for lightning, particles.
                CustomPaint(
                  painter: _GamePainter(
                    zeus: _zeus,
                    aim: _aim,
                    charge: _charge,
                    charging: _charging,
                    bolts: _bolts,
                    particles: _particles,
                    shield: _shieldTime > 0,
                    zeusRadius: _zeusRadius,
                  ),
                  size: Size.infinite,
                ),

                // Collectibles.
                ..._collectibles.map(_buildCollectible),

                // Enemies.
                ..._enemies.map(_buildEnemy),

                // Zeus hero.
                Positioned(
                  left: _zeus.dx - 70,
                  top: _zeus.dy - 90,
                  width: 140,
                  height: 180,
                  child: IgnorePointer(
                    child: Image.asset(
                      'assets/Hero.webp',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),

                // HUD.
                SafeArea(child: _buildHud()),

                // Pause overlay.
                if (_paused && !_gameOver) _buildPauseMenu(),

                // Game over overlay.
                if (_gameOver) _buildGameOver(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildEnemy(Enemy e) {
    late String asset;
    switch (e.kind) {
      case EnemyKind.harpy:
        asset = 'assets/Enemy_Harpy.webp';
        break;
      case EnemyKind.cyclops:
        asset = 'assets/Enemy_Cyclops.webp';
        break;
      case EnemyKind.medusa:
        asset = 'assets/Enemy_Medusa.webp';
        break;
      case EnemyKind.minotaur:
        asset = 'assets/Enemy_Minotaur.webp';
        break;
    }
    final size = e.size;
    return Positioned(
      left: e.pos.dx - size / 2,
      top: e.pos.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            ColorFiltered(
              colorFilter: e.flashTimer > 0
                  ? const ColorFilter.mode(
                      Color(0xAAFFFFFF), BlendMode.srcATop)
                  : const ColorFilter.mode(
                      Colors.transparent, BlendMode.dst),
              child: Image.asset(asset, fit: BoxFit.contain),
            ),
            if (e.maxHp > 1)
              Positioned(
                top: 0,
                child: Container(
                  width: size * 0.7,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: (e.hp / e.maxHp).clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5252),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollectible(Collectible c) {
    String asset;
    Color halo;
    switch (c.kind) {
      case 'coin':
        asset = 'assets/Collectible_GoldenCoin.webp';
        halo = const Color(0xFFFFC93A);
        break;
      case 'lightning':
        asset = 'assets/Collectible_Lightning.webp';
        halo = const Color(0xFF66E1FF);
        break;
      case 'ambrosia':
        asset = 'assets/Collectible_Ambrosia.webp';
        halo = const Color(0xFFFF6EC7);
        break;
      case 'shield':
        asset = 'assets/Powerup_DivineShield.webp';
        halo = const Color(0xFF66E1FF);
        break;
      case 'storm':
        asset = 'assets/Powerup_StormRage.webp';
        halo = const Color(0xFFFF6E3A);
        break;
      default:
        asset = 'assets/Collectible_GoldenCoin.webp';
        halo = const Color(0xFFFFC93A);
    }
    final bob = math.sin(c.phase * 3.0) * 4;
    final pulse = 0.5 + 0.5 * math.sin(c.phase * 4.0);
    return Positioned(
      left: c.pos.dx - 34,
      top: c.pos.dy - 34 + bob,
      width: 68,
      height: 68,
      child: IgnorePointer(
        child: Opacity(
          opacity: c.life > 1.5 ? 1.0 : (c.life / 1.5).clamp(0.2, 1.0),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      halo.withOpacity(0.35 + 0.25 * pulse),
                      halo.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Image.asset(asset, fit: BoxFit.contain),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHud() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StatChip(icon: Icons.star_rounded, label: '$_score',
                  color: const Color(0xFFFFC93A)),
              const SizedBox(width: 8),
              _StatChip(
                  icon: Icons.bolt_rounded,
                  label: '$_energy',
                  color: const Color(0xFF66E1FF)),
              const Spacer(),
              _StatChip(
                  icon: Icons.timer_outlined,
                  label: '${_time.toInt()}s',
                  color: Colors.white),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _paused = !_paused),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Icon(
                    _paused ? Icons.play_arrow : Icons.pause,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_shieldTime > 0)
                _TimerBadge(
                  label: 'Shield',
                  color: const Color(0xFF66E1FF),
                  time: _shieldTime,
                ),
              if (_stormRageTime > 0) ...[
                const SizedBox(width: 6),
                _TimerBadge(
                  label: 'Storm Rage',
                  color: const Color(0xFFFF6E3A),
                  time: _stormRageTime,
                ),
              ],
              const Spacer(),
              _UpgradeButton(
                icon: Icons.flash_on,
                label: 'PWR ${_powerLevel > 0 ? "+$_powerLevel" : ""}',
                cost: 40 + _powerLevel * 30,
                canAfford: _energy >= 40 + _powerLevel * 30,
                onTap: _upgradePower,
              ),
              const SizedBox(width: 6),
              _UpgradeButton(
                icon: Icons.speed,
                label: 'SPD ${_speedLevel > 0 ? "+$_speedLevel" : ""}',
                cost: 40 + _speedLevel * 30,
                canAfford: _energy >= 40 + _speedLevel * 30,
                onTap: _upgradeSpeed,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGameOver() {
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'THUNDER PEAK\nHAS FALLEN',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFFFC93A),
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  height: 1.1,
                  letterSpacing: 2,
                  shadows: [Shadow(blurRadius: 12, color: Colors.black)],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Score: $_score',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Enemies defeated: $_kills',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              Text(
                'Survived: ${_time.toInt()}s',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 24),
              _PrimaryButton(
                icon: Icons.refresh_rounded,
                label: 'PLAY AGAIN',
                onTap: _restart,
              ),
              const SizedBox(height: 12),
              _PrimaryButton(
                icon: Icons.home_rounded,
                label: 'MAIN MENU',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPauseMenu() {
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF10214A), Color(0xFF06102C)],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: const Color(0xFFFFC93A).withOpacity(0.6),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF66E1FF).withOpacity(0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.pause_circle_filled_rounded,
                    color: Color(0xFFFFC93A), size: 44),
                const SizedBox(height: 6),
                const Text(
                  'PAUSED',
                  style: TextStyle(
                    color: Color(0xFFFFC93A),
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                    shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                  ),
                ),
                const SizedBox(height: 22),
                _PrimaryButton(
                  icon: Icons.play_arrow_rounded,
                  label: 'RESUME',
                  onTap: () => setState(() => _paused = false),
                ),
                const SizedBox(height: 12),
                _PrimaryButton(
                  icon: Icons.home_rounded,
                  label: 'MAIN MENU',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: 260,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFFC93A), Color(0xFFFF6E3A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(0.9),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFC93A).withOpacity(0.45),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: Colors.white, size: 26),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black45)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.6), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimerBadge extends StatelessWidget {
  const _TimerBadge({
    required this.label,
    required this.color,
    required this.time,
  });

  final String label;
  final Color color;
  final double time;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        '$label ${time.toStringAsFixed(1)}s',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _UpgradeButton extends StatelessWidget {
  const _UpgradeButton({
    required this.icon,
    required this.label,
    required this.cost,
    required this.canAfford,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int cost;
  final bool canAfford;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: canAfford ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: canAfford
              ? const Color(0xFF10214A).withOpacity(0.85)
              : Colors.black45,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: canAfford
                ? const Color(0xFFFFC93A)
                : Colors.white24,
            width: 1.2,
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    color: canAfford ? const Color(0xFFFFC93A) : Colors.white54,
                    size: 16),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: canAfford ? Colors.white : Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            Text(
              '$cost⚡',
              style: TextStyle(
                color: canAfford
                    ? const Color(0xFF66E1FF)
                    : Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GamePainter extends CustomPainter {
  _GamePainter({
    required this.zeus,
    required this.aim,
    required this.charge,
    required this.charging,
    required this.bolts,
    required this.particles,
    required this.shield,
    required this.zeusRadius,
  });

  final Offset zeus;
  final Offset aim;
  final double charge;
  final bool charging;
  final List<LightningBolt> bolts;
  final List<Particle> particles;
  final bool shield;
  final double zeusRadius;

  final math.Random _rng = math.Random(1);

  @override
  void paint(Canvas canvas, Size size) {
    // Shield.
    if (shield) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFF66E1FF).withOpacity(0.7);
      canvas.drawCircle(zeus, zeusRadius + 18, p);
      final glow = Paint()
        ..color = const Color(0x3366E1FF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawCircle(zeus, zeusRadius + 20, glow);
    }

    // Charge indicator around Zeus.
    if (charging) {
      final baseR = zeusRadius + 10;
      final r = baseR + charge * 30;
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 + charge * 4
        ..shader = SweepGradient(
          colors: [
            const Color(0xFF66E1FF).withOpacity(0.2 + charge * 0.6),
            const Color(0xFFFFD84D).withOpacity(0.2 + charge * 0.6),
            const Color(0xFF66E1FF).withOpacity(0.2 + charge * 0.6),
          ],
        ).createShader(Rect.fromCircle(center: zeus, radius: r));
      canvas.drawCircle(zeus, r, ringPaint);

      // Aim line preview.
      final aimPaint = Paint()
        ..color = Colors.white.withOpacity(0.25 + charge * 0.4)
        ..strokeWidth = 1.5;
      canvas.drawLine(zeus, aim, aimPaint);

      // Aim reticle.
      final reticle = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withOpacity(0.5 + charge * 0.5);
      canvas.drawCircle(aim, 18 + charge * 10, reticle);
      canvas.drawLine(aim + const Offset(-24, 0), aim + const Offset(-8, 0),
          reticle);
      canvas.drawLine(aim + const Offset(24, 0), aim + const Offset(8, 0),
          reticle);
      canvas.drawLine(aim + const Offset(0, -24), aim + const Offset(0, -8),
          reticle);
      canvas.drawLine(aim + const Offset(0, 24), aim + const Offset(0, 8),
          reticle);

      // Charging particles converging on zeus.
      final glow = Paint()
        ..color = const Color(0xFF66E1FF).withOpacity(0.15 + charge * 0.4)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + charge * 14);
      canvas.drawCircle(zeus, 30 + charge * 30, glow);
    }

    // Lightning bolts.
    for (final b in bolts) {
      _drawLightning(canvas, b);
    }

    // Particles.
    for (final p in particles) {
      final t = (p.life / p.maxLife).clamp(0.0, 1.0);
      final paint = Paint()..color = p.color.withOpacity(t);
      canvas.drawCircle(p.pos, p.size * t + 0.5, paint);
    }
  }

  void _drawLightning(Canvas canvas, LightningBolt b) {
    final tFrac = (b.life / 0.35).clamp(0.0, 1.0);
    final alpha = tFrac;
    final segments = 14;
    final direction = b.end - b.start;
    final len = direction.distance;
    if (len < 1) return;

    // Two parallel jagged strokes for a fatter look.
    for (int layer = 0; layer < 2; layer++) {
      final path = Path()..moveTo(b.start.dx, b.start.dy);
      final jitter = 18.0 - layer * 6;
      for (int i = 1; i < segments; i++) {
        final f = i / segments;
        final base = b.start + direction * f;
        final normal = Offset(-direction.dy, direction.dx) / len;
        final j = (_rng.nextDouble() - 0.5) * jitter * (1 - f * 0.2);
        final pt = base + normal * j;
        path.lineTo(pt.dx, pt.dy);
      }
      path.lineTo(b.end.dx, b.end.dy);

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = b.width * (layer == 0 ? 1.0 : 0.5)
        ..color = (layer == 0
                ? const Color(0xFF66E1FF)
                : Colors.white)
            .withOpacity(alpha);
      if (layer == 0) {
        paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      }
      canvas.drawPath(path, paint);
    }

    // Impact glow.
    final glow = Paint()
      ..color = const Color(0xFFFFD84D).withOpacity(alpha * 0.7)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(b.end, 24 + b.power * 30, glow);
    final impact = Paint()
      ..color = Colors.white.withOpacity(alpha);
    canvas.drawCircle(b.end, 6 + b.power * 6, impact);
  }

  @override
  bool shouldRepaint(covariant _GamePainter oldDelegate) => true;
}
