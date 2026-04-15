import 'dart:ui';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:screenshot/screenshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================
// CONFIGURATION
// ============================================
const String VPS_SERVER_IP = '76.13.255.239';
const double EXCHANGE_RATE = 242.0;

// ============================================
// CART STATE
// ============================================
class CartItem {
  final String name;
  final String image;
  final double priceUSD;
  int quantity;

  CartItem({
    required this.name,
    required this.image,
    required this.priceUSD,
    this.quantity = 1,
  });

  double get lineUSDT => priceUSD * 1.10 * quantity;
  double get lineDZD => lineUSDT * EXCHANGE_RATE;

  Map<String, dynamic> toJson() => {
        'name': name,
        'image': image,
        'priceUSD': priceUSD,
        'quantity': quantity,
      };

  factory CartItem.fromJson(Map<String, dynamic> j) => CartItem(
        name: j['name'] as String,
        image: j['image'] as String,
        priceUSD: (j['priceUSD'] as num).toDouble(),
        quantity: (j['quantity'] as num?)?.toInt() ?? 1,
      );
}

class Cart {
  static final List<CartItem> items = [];
  static final _listeners = <VoidCallback>[];

  static void addListener(VoidCallback cb) => _listeners.add(cb);
  static void removeListener(VoidCallback cb) => _listeners.remove(cb);
  static void _notify() {
    for (final cb in _listeners) {
      cb();
    }
    save();
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = items.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList('cart_items', encoded);
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getStringList('cart_items') ?? [];
    items.clear();
    for (final s in encoded) {
      try {
        items.add(CartItem.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
  }

  static void add(CartItem newItem) {
    // Match on name + image so different variants (colors/sizes) are separate entries
    final idx = items.indexWhere(
        (i) => i.name == newItem.name && i.image == newItem.image);
    if (idx >= 0) {
      items[idx].quantity++;
    } else {
      items.add(newItem);
    }
    _notify();
  }

  static void remove(int index) {
    if (index >= 0 && index < items.length) {
      items.removeAt(index);
      _notify();
    }
  }

  static void decrement(int index) {
    if (index >= 0 && index < items.length) {
      if (items[index].quantity > 1) {
        items[index].quantity--;
      } else {
        items.removeAt(index);
      }
      _notify();
    }
  }

  static double get totalUSDT =>
      items.fold(0.0, (s, i) => s + i.lineUSDT);
  static double get totalDZD => totalUSDT * EXCHANGE_RATE;
}

// ============================================
// USER PROFILE
// ============================================
class UserProfile {
  static String name = '';
  static String phone = '';
  static String email = '';
  static String address = '';
  static double balance = 0.0; // USDT credit balance

  static bool get isEmpty => name.trim().isEmpty || phone.trim().isEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    name    = prefs.getString('profile_name')    ?? '';
    phone   = prefs.getString('profile_phone')   ?? '';
    email   = prefs.getString('profile_email')   ?? '';
    address = prefs.getString('profile_address') ?? '';
    balance = prefs.getDouble('profile_balance') ?? 0.0;
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_name',    name);
    await prefs.setString('profile_phone',   phone);
    await prefs.setString('profile_email',   email);
    await prefs.setString('profile_address', address);
    await prefs.setDouble('profile_balance', balance);
  }

  /// Fetch balance from server and update local cache.
  /// Silent — never throws; returns true if synced successfully.
  static Future<bool> syncBalance() async {
    if (phone.trim().isEmpty) return false;
    try {
      final uri = Uri.parse(
          'http://$VPS_SERVER_IP:3000/balance?phone=${Uri.encodeComponent(phone.trim())}');
      final response =
          await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        balance = (data['balance'] as num?)?.toDouble() ?? balance;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('profile_balance', balance);
        return true;
      }
    } catch (_) {}
    return false;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([Cart.load(), UserProfile.load()]);
  runApp(const TchipaApp());
}

// ============================================
// APP PRINCIPALE
// ============================================
class TchipaApp extends StatelessWidget {
  const TchipaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'tchipa',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        primaryColor: const Color(0xFF00D4FF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D4FF),
          brightness: Brightness.dark,
        ),
        fontFamily: 'SF Pro Display',
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0F1923),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// ============================================
// SPLASH SCREEN
// ============================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Image fades in over 800 ms
  late AnimationController _imgCtrl;
  late Animation<double> _imgFade;

  // Overlay (name + spinner) slides up after image settles
  late AnimationController _overlayCtrl;
  late Animation<double> _overlayFade;
  late Animation<Offset> _overlaySlide;

  static const String _splashImage =
      'https://i.ibb.co/QF18Dz91/Gemini-Generated-Image-1h03up1h03up1h03.png';

  @override
  void initState() {
    super.initState();

    _imgCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _imgFade = CurvedAnimation(parent: _imgCtrl, curve: Curves.easeIn);

    _overlayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _overlayFade  = CurvedAnimation(parent: _overlayCtrl, curve: Curves.easeIn);
    _overlaySlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _overlayCtrl, curve: Curves.easeOut));

    _imgCtrl.forward().then((_) => _overlayCtrl.forward());

    // Navigate after 3.2 s total
    Future.delayed(const Duration(milliseconds: 3200), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MainScreen(),
          transitionDuration: const Duration(milliseconds: 600),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    });
  }

  @override
  void dispose() {
    _imgCtrl.dispose();
    _overlayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Full-screen splash image ──
          FadeTransition(
            opacity: _imgFade,
            child: Image.network(
              _splashImage,
              width: size.width,
              height: size.height,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: const Color(0xFF0D1117),
                child: const Center(
                  child: Icon(Icons.image_not_supported_outlined,
                      color: Colors.white24, size: 64),
                ),
              ),
            ),
          ),

          // ── Dark gradient scrim at the bottom ──
          Positioned(
            left: 0, right: 0, bottom: 0,
            height: size.height * 0.45,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.85),
                  ],
                ),
              ),
            ),
          ),

          // ── App name + spinner overlay ──
          Positioned(
            left: 0, right: 0, bottom: 52,
            child: SlideTransition(
              position: _overlaySlide,
              child: FadeTransition(
                opacity: _overlayFade,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                      ).createShader(bounds),
                      child: const Text(
                        'tchipa',
                        style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Smart Checkout · AliExpress & Temu',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 13,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          const Color(0xFF00D4FF).withOpacity(0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================
// ECRAN PRINCIPAL
// ============================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const HomeScreen(),
    const CartScreen(),
    const HistoryScreen(),
    const ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    Cart.addListener(_onCartChanged);
    // If profile is incomplete, redirect to Profile tab after first frame
    if (UserProfile.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _currentIndex = 3);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(children: [
              Icon(Icons.person_outline, color: Color(0xFF00D4FF)),
              SizedBox(width: 10),
              Text('Complétez votre profil pour commencer',
                  style: TextStyle(color: Colors.white)),
            ]),
            backgroundColor: const Color(0xFF0F1923),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 3),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    Cart.removeListener(_onCartChanged);
    super.dispose();
  }

  void _onCartChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0F1923), Color(0xFF0D1117)],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: const Color(0xFF00D4FF),
          unselectedItemColor: Colors.white38,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: 'Accueil',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                label: Cart.items.isEmpty
                    ? null
                    : Text('${Cart.items.length}'),
                isLabelVisible: Cart.items.isNotEmpty,
                child: const Icon(Icons.shopping_cart_rounded),
              ),
              label: 'Panier',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.history_rounded),
              label: 'Historique',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                isLabelVisible: UserProfile.isEmpty,
                label: const Text('!'),
                child: const Icon(Icons.person_rounded),
              ),
              label: 'Profil',
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================
// ECRAN D'ACCUEIL - SCANNER PRODUIT
// ============================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final ScreenshotController _screenshotController = ScreenshotController();

  bool _isLoading = false;
  double _originalPrice = 0.0;
  double _totalUsdt = 0.0;
  double _totalDzd = 0.0;
  String _orderID = "";
  String _productName = "";
  String _productImage = "";

  late AnimationController _flagController;
  late Animation<double> _flagAnimation;

  @override
  void initState() {
    super.initState();
    _flagController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _flagAnimation =
        Tween<double>(begin: 0, end: 2 * pi).animate(_flagController);
    // Sync balance from server in the background after the frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final synced = await UserProfile.syncBalance();
      if (synced && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _flagController.dispose();
    _linkController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  // --- RAPIDAPI VPS ---
  Future<void> _fetchPriceFromScraper() async {
    String url = _linkController.text.trim();
    if (url.isEmpty) {
      _showToast("Veuillez entrer un lien produit");
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await http
          .get(Uri.parse(
              'http://$VPS_SERVER_IP:3000/browse?url=${Uri.encodeComponent(url)}'))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final name = data['productName']?.toString() ?? '';
        final price = (data['priceUSD'] as num?)?.toDouble() ?? 0.0;
        final image = data['imageUrl']?.toString() ?? '';

        if (name.isEmpty && price == 0) {
          _showToast("Produit non trouvé. Entrez le prix manuellement.");
          return;
        }

        setState(() {
          _productName = name.isNotEmpty ? name : 'Produit AliExpress';
          _productImage = image;
          _priceController.text = price > 0 ? price.toStringAsFixed(2) : '';
          if (price > 0) _calculate();
        });
        _showToast("Produit détecté !");
      } else {
        _showToast("Produit non trouvé. Entrez le prix manuellement.");
      }
    } catch (e) {
      _showToast("Erreur de connexion. Entrez le prix manuellement.");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _onLinkChanged(String value) {
    final trimmed = value.trim();
    if ((trimmed.contains('aliexpress.com/item/') ||
            trimmed.contains('aliexpress.com/i/')) &&
        !_isLoading) {
      _fetchPriceFromScraper();
    }
  }

  void _calculate() {
    setState(() {
      _originalPrice = double.tryParse(_priceController.text) ?? 0.0;
      _totalUsdt = _originalPrice * 1.10;
      _totalDzd = _totalUsdt * EXCHANGE_RATE;
      _orderID = "NP-${Random().nextInt(9000) + 1000}";
    });
  }

  // --- DIALOG QR CODE ---
  void _showCouponDialog() {
    if (_totalUsdt <= 0) {
      _showToast("Calculez d'abord un prix");
      return;
    }

    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF0F1923),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Screenshot(
                controller: _screenshotController,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF00D4FF).withOpacity(0.1),
                        const Color(0xFF8B5CF6).withOpacity(0.1),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildMiniAlgerianFlag(),
                          const SizedBox(width: 10),
                          const Text(
                            "TCHIPA",
                            style: TextStyle(
                              color: Color(0xFF00D4FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: QrImageView(
                          data: "TCHIPA|$_orderID"
                              "|${_totalUsdt.toStringAsFixed(2)}|USDT"
                              "|NOM:${UserProfile.name}"
                              "|TEL:${UserProfile.phone}",
                          version: QrVersions.auto,
                          size: 180,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Color(0xFF00D4FF),
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      Text(
                        "ID: $_orderID",
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        "${_totalUsdt.toStringAsFixed(2)} USDT",
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00D4FF),
                        ),
                      ),
                      Text(
                        "~ ${_totalDzd.toStringAsFixed(0)} DZD",
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fermer",
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: _shareCoupon,
              icon: const Icon(Icons.share),
              label: const Text("Partager"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D4FF),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareCoupon() async {
    final image = await _screenshotController.capture();
    if (image != null) {
      await Share.shareXFiles(
        [
          XFile.fromData(image,
              name: 'tchipa_coupon.png', mimeType: 'image/png')
        ],
        text:
            'Tchipa - Commande $_orderID - ${_totalUsdt.toStringAsFixed(2)} USDT',
      );
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF0F1923),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0D1117),
              Color(0xFF0F1923),
              Color(0xFF0D1117),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 10),
                _buildHeader(),
                const SizedBox(height: 30),
                _buildInputCard(),
                const SizedBox(height: 20),
                if (_productName.isNotEmpty) _buildProductCard(),
                if (_totalUsdt > 0) ...[
                  const SizedBox(height: 20),
                  _buildResultCard(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        // Tchipa logo — layered neon cyan glow ring
        Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            // Outer diffuse purple halo
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00D4FF).withOpacity(0.70),
                blurRadius: 36,
                spreadRadius: 6,
              ),
              BoxShadow(
                color: const Color(0xFF8B5CF6).withOpacity(0.45),
                blurRadius: 64,
                spreadRadius: 16,
              ),
            ],
          ),
          child: Stack(
            children: [
              // Cyan neon border ring
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              // Inner logo (3 px inset from the border)
              Positioned(
                top: 3,
                left: 3,
                right: 3,
                bottom: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(25),
                  child: Image.network(
                    'https://i.ibb.co/6R2N7B1X/1000022003.jpg',
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Image.asset(
                      'assets/nearpay_logo.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 600.ms).scale(begin: const Offset(0.8, 0.8)),
        const SizedBox(height: 14),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
          ).createShader(bounds),
          child: const Text(
            "TCHIPA",
            style: TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 5,
            ),
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 200.ms),
        const SizedBox(height: 4),
        Text(
          "Smart Checkout · AliExpress & Temu",
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 13,
            letterSpacing: 0.5,
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 400.ms),
        const SizedBox(height: 18),
        // Animated Algerian flag with rotating diamond star
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF006233).withOpacity(0.35),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 150,
              height: 100,
              child: Stack(
                children: [
                  Image.network(
                    'https://i.ibb.co/bjRzHSk2/Gemini-Generated-Image-xnu9ukxnu9ukxnu9-1.png',
                    width: 150,
                    height: 100,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => AnimatedBuilder(
                      animation: _flagController,
                      builder: (_, __) => CustomPaint(
                        size: const Size(150, 100),
                        painter: AlgerianFlagPainter(
                          _flagAnimation.value,
                          starPhase: _flagAnimation.value,
                        ),
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _flagController,
                    builder: (_, __) => CustomPaint(
                      size: const Size(150, 100),
                      painter: _StarOverlayPainter(_flagAnimation.value),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ).animate().fadeIn(duration: 700.ms, delay: 500.ms),
        if (!UserProfile.isEmpty) ...[
          const SizedBox(height: 14),
          _buildBalanceChip(),
        ],
      ],
    );
  }

  Widget _buildBalanceChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF00D4FF).withOpacity(0.15),
            const Color(0xFF8B5CF6).withOpacity(0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.account_balance_wallet_rounded,
              color: Color(0xFF00D4FF), size: 16),
          const SizedBox(width: 8),
          Text(
            "Solde : ${UserProfile.balance.toStringAsFixed(2)} USDT",
            style: const TextStyle(
              color: Color(0xFF00D4FF),
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 500.ms, delay: 600.ms);
  }

  Widget _buildMiniAlgerianFlag() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        'https://i.ibb.co/bjRzHSk2/Gemini-Generated-Image-xnu9ukxnu9ukxnu9-1.png',
        width: 50,
        height: 34,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => AnimatedBuilder(
          animation: _flagController,
          builder: (_, __) => CustomPaint(
            size: const Size(50, 34),
            painter: AlgerianFlagPainter(
              _flagAnimation.value,
              isMini: true,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputCard() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.1),
            Colors.white.withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Lien produit
          TextField(
            controller: _linkController,
            style: const TextStyle(color: Colors.white),
            onChanged: _onLinkChanged,
            decoration: InputDecoration(
              hintText: "Collez le lien AliExpress ou Temu",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.link, color: Color(0xFF00D4FF)),
              suffixIcon: _isLoading
                  ? Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.all(12),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00D4FF),
                      ),
                    )
                  : IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.search,
                            color: Colors.black, size: 18),
                      ),
                      onPressed: _fetchPriceFromScraper,
                    ),
            ),
          ),
          const SizedBox(height: 15),
          // Prix manuel
          TextField(
            controller: _priceController,
            style: const TextStyle(color: Colors.white, fontSize: 24),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _calculate(),
            decoration: InputDecoration(
              hintText: "Prix en \$",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide.none,
              ),
              prefixIcon:
                  const Icon(Icons.attach_money, color: Color(0xFF00D4FF)),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 600.ms, delay: 600.ms).slideY(begin: 0.2);
  }

  Widget _buildProductCard() {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(
              productName: _productName,
              productImage: _productImage,
              priceUSD: _originalPrice,
              priceUSDT: _totalUsdt,
              priceDZD: _totalDzd,
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF00D4FF).withOpacity(0.1),
              const Color(0xFF8B5CF6).withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: const Color(0xFF00D4FF).withOpacity(0.3)),
        ),
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shopping_bag,
                    color: Color(0xFF00D4FF), size: 20),
                const SizedBox(width: 8),
                const Text(
                  "Produit détecté",
                  style: TextStyle(
                    color: Color(0xFF00D4FF),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right,
                    color: Colors.white38, size: 20),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _productName,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            if (_productImage.isNotEmpty) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  _productImage,
                  height: 100,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.visibility_rounded,
                      color: Colors.black, size: 16),
                  SizedBox(width: 6),
                  Text(
                    "Voir le détail",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1);
  }

  Widget _buildResultCard() {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF00D4FF).withOpacity(0.15),
                const Color(0xFF8B5CF6).withOpacity(0.1),
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
                color: const Color(0xFF00D4FF).withOpacity(0.3)),
          ),
          padding: const EdgeInsets.all(25),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Prix original",
                    style: TextStyle(color: Colors.white.withOpacity(0.6)),
                  ),
                  Text(
                    "\$${_originalPrice.toStringAsFixed(2)}",
                    style:
                        const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "TOTAL À PAYER",
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00D4FF),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text(
                                "USDT",
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _totalUsdt.toStringAsFixed(2),
                              style: const TextStyle(
                                color: Color(0xFF00D4FF),
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Icon(
                      Icons.trending_up,
                      color: Color(0xFF00D4FF),
                      size: 40,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Estimation DZD",
                    style: TextStyle(color: Colors.white.withOpacity(0.6)),
                  ),
                  Text(
                    "~ ${_totalDzd.toStringAsFixed(0)} DA",
                    style: const TextStyle(
                      color: Color(0xFF8B5CF6),
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                "Taux: 1 USDT = $EXCHANGE_RATE DZD",
                style: TextStyle(
                    color: Colors.white.withOpacity(0.4), fontSize: 11),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.2),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _showCouponDialog,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            child: Ink(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Container(
                padding: const EdgeInsets.all(20),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.qr_code_2, color: Colors.black, size: 28),
                    SizedBox(width: 10),
                    Text(
                      "GÉNÉRER LE QR CODE",
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ).animate().fadeIn(duration: 600.ms, delay: 200.ms),
      ],
    );
  }
}

// ============================================
// ECRAN PANIER
// ============================================
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final ScreenshotController _screenshotController = ScreenshotController();
  String _orderID = "";

  @override
  void initState() {
    super.initState();
    Cart.addListener(_onCartChanged);
    _orderID = "NP-${Random().nextInt(9000) + 1000}";
  }

  @override
  void dispose() {
    Cart.removeListener(_onCartChanged);
    super.dispose();
  }

  void _onCartChanged() => setState(() {});

  void _showQrDialog() {
    if (Cart.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Le panier est vide"),
          backgroundColor: const Color(0xFF0F1923),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    _orderID = "NP-${Random().nextInt(9000) + 1000}";

    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF0F1923),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          content: SingleChildScrollView(
            child: Screenshot(
              controller: _screenshotController,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF00D4FF).withOpacity(0.1),
                      const Color(0xFF8B5CF6).withOpacity(0.1),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    const Text(
                      "TCHIPA",
                      style: TextStyle(
                        color: Color(0xFF00D4FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Commande $_orderID",
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    // QR Code
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: QrImageView(
                        data: "TCHIPA|$_orderID"
                            "|${Cart.totalUSDT.toStringAsFixed(2)}|USDT"
                            "|${Cart.items.length}articles"
                            "|NOM:${UserProfile.name}"
                            "|TEL:${UserProfile.phone}",
                        version: QrVersions.auto,
                        size: 200,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Color(0xFF00D4FF),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Items summary
                    ...Cart.items.map((item) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Text(
                                "×${item.quantity}",
                                style: const TextStyle(
                                    color: Color(0xFF00D4FF),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item.name,
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                "${item.lineUSDT.toStringAsFixed(2)} USDT",
                                style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11),
                              ),
                            ],
                          ),
                        )),
                    const Divider(color: Colors.white12, height: 20),
                    // Total USDT
                    Text(
                      "${Cart.totalUSDT.toStringAsFixed(2)} USDT",
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00D4FF),
                      ),
                    ),
                    // Total DZD
                    Text(
                      "≈ ${Cart.totalDZD.toStringAsFixed(0)} DZD",
                      style: const TextStyle(
                          color: Color(0xFF8B5CF6), fontSize: 15),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "1 USDT = $EXCHANGE_RATE DZD",
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fermer",
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final image = await _screenshotController.capture();
                if (image != null && context.mounted) {
                  Navigator.pop(context);
                  await Share.shareXFiles(
                    [
                      XFile.fromData(image,
                          name: 'tchipa_panier.png',
                          mimeType: 'image/png')
                    ],
                    text:
                        'Tchipa - Commande $_orderID - ${Cart.totalUSDT.toStringAsFixed(2)} USDT',
                  );
                }
              },
              icon: const Icon(Icons.share),
              label: const Text("Partager"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D4FF),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF0F1923)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.shopping_cart_rounded,
                    color: Colors.black),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Mon Panier",
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "${Cart.items.length} article${Cart.items.length != 1 ? 's' : ''}",
                    style: const TextStyle(
                        color: Color(0xFF00D4FF), fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            if (Cart.items.isNotEmpty)
              TextButton(
                onPressed: () {
                  setState(() => Cart.items.clear());
                },
                child: const Text("Vider",
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
              ),
          ],
        ),
        body: Cart.items.isEmpty
            ? _buildEmptyCart()
            : Column(
                children: [
                  Expanded(child: _buildItemList()),
                  _buildTotalBar(),
                ],
              ),
      ),
    );
  }

  Widget _buildEmptyCart() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00D4FF).withOpacity(0.15),
                  const Color(0xFF8B5CF6).withOpacity(0.1),
                ],
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.shopping_cart_outlined,
              size: 56,
              color: Color(0xFF00D4FF),
            ),
          ).animate().scale(duration: 600.ms),
          const SizedBox(height: 20),
          Text(
            "Panier vide",
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ).animate().fadeIn(delay: 200.ms),
          const SizedBox(height: 8),
          Text(
            "Ajoutez des produits depuis l'accueil",
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 14,
            ),
          ).animate().fadeIn(delay: 300.ms),
        ],
      ),
    );
  }

  Widget _buildItemList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: Cart.items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = Cart.items[index];
        return Dismissible(
          key: ValueKey(item.name),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.3),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.delete_rounded,
                color: Colors.redAccent),
          ),
          onDismissed: (_) => Cart.remove(index),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.08),
                  Colors.white.withOpacity(0.04),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border:
                  Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Image
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: item.image.isNotEmpty
                      ? Image.network(
                          item.image,
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _itemImagePlaceholder(),
                        )
                      : _itemImagePlaceholder(),
                ),
                const SizedBox(width: 12),
                // Name & price
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "\$${item.priceUSD.toStringAsFixed(2)} / unité",
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "${item.lineUSDT.toStringAsFixed(2)} USDT",
                        style: const TextStyle(
                          color: Color(0xFF00D4FF),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "≈ ${item.lineDZD.toStringAsFixed(0)} DZD",
                        style: const TextStyle(
                            color: Color(0xFF8B5CF6), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Quantity controls
                Column(
                  children: [
                    GestureDetector(
                      onTap: () => Cart.add(CartItem(
                        name: item.name,
                        image: item.image,
                        priceUSD: item.priceUSD,
                      )),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF00D4FF),
                              Color(0xFF8B5CF6)
                            ],
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.add,
                            color: Colors.black, size: 18),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "${item.quantity}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => Cart.decrement(index),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.15)),
                        ),
                        child: const Icon(Icons.remove,
                            color: Colors.white54, size: 18),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _itemImagePlaceholder() {
    return Container(
      width: 58,
      height: 58,
      color: const Color(0xFF0F1923),
      child: const Icon(Icons.shopping_bag_outlined,
          color: Colors.white12, size: 28),
    );
  }

  Widget _buildTotalBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Totals row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Total",
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12),
                  ),
                  Text(
                    "${Cart.totalUSDT.toStringAsFixed(2)} USDT",
                    style: const TextStyle(
                      color: Color(0xFF00D4FF),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "≈ ${Cart.totalDZD.toStringAsFixed(0)} DZD",
                    style: const TextStyle(
                        color: Color(0xFF8B5CF6), fontSize: 13),
                  ),
                ],
              ),
              Text(
                "${Cart.items.fold(0, (s, i) => s + i.quantity)} art.",
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // QR Button
          GestureDetector(
            onTap: _showQrDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_2, color: Colors.black, size: 26),
                  SizedBox(width: 10),
                  Text(
                    "Générer QR Code",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================
// ECRAN HISTORIQUE
// ============================================
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF0F1923)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            "Historique",
            style: TextStyle(color: Colors.white),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.history, size: 80, color: Colors.white.withOpacity(0.2)),
              const SizedBox(height: 20),
              Text(
                "Aucun historique",
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "Vos commandes apparaîtront ici",
                style: TextStyle(
                  color: Colors.white.withOpacity(0.2),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================
// ECRAN DÉTAIL PRODUIT
// ============================================
class ProductDetailScreen extends StatefulWidget {
  final String productName;
  final String productImage;
  final double priceUSD;
  final double priceUSDT;
  final double priceDZD;

  const ProductDetailScreen({
    super.key,
    required this.productName,
    required this.productImage,
    required this.priceUSD,
    required this.priceUSDT,
    required this.priceDZD,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen>
    with SingleTickerProviderStateMixin {
  bool _addedToCart = false;
  late AnimationController _btnController;
  late Animation<double> _btnScale;

  @override
  void initState() {
    super.initState();
    _btnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      lowerBound: 0.93,
      upperBound: 1.0,
      value: 1.0,
    );
    _btnScale = _btnController;
  }

  @override
  void dispose() {
    _btnController.dispose();
    super.dispose();
  }

  void _addToCart() async {
    await _btnController.reverse();
    await _btnController.forward();

    Cart.add(CartItem(
      name: widget.productName,
      image: widget.productImage,
      priceUSD: widget.priceUSD,
    ));

    setState(() => _addedToCart = true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF00D4FF)),
            SizedBox(width: 10),
            Text("Ajouté au panier !",
                style: TextStyle(color: Colors.white)),
          ],
        ),
        backgroundColor: const Color(0xFF0F1923),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            backgroundColor: const Color(0xFF0D1117),
            leading: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: widget.productImage.isNotEmpty
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(
                          widget.productImage,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _imagePlaceholder(),
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          height: 120,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  const Color(0xFF0D1117),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _imagePlaceholder(),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.productName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                    ),
                  ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF0F1923), Color(0xFF0D1117)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.08)),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildPriceRow(
                          icon: Icons.attach_money,
                          iconColor: Colors.white54,
                          label: "Prix USD",
                          value:
                              "\$${widget.priceUSD.toStringAsFixed(2)}",
                          valueColor: Colors.white70,
                          fontSize: 16,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child:
                              Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.currency_bitcoin,
                          iconColor: const Color(0xFF26A17B),
                          label: "USDT",
                          value:
                              "${widget.priceUSDT.toStringAsFixed(2)} USDT",
                          valueColor: const Color(0xFF26A17B),
                          fontSize: 22,
                          bold: true,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child:
                              Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.flag_rounded,
                          iconColor: const Color(0xFF006233),
                          label: "DZD",
                          value:
                              "~ ${widget.priceDZD.toStringAsFixed(0)} دج",
                          valueColor: const Color(0xFF8B5CF6),
                          fontSize: 22,
                          bold: true,
                        ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 500.ms, delay: 100.ms).slideY(begin: 0.15),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 13, color: Colors.white24),
                      const SizedBox(width: 6),
                      Text(
                        "Taux indicatif · 1 USDT = $EXCHANGE_RATE DZD",
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 12),
                      ),
                    ],
                  ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.06))),
        ),
        child: ScaleTransition(
          scale: _btnScale,
          child: GestureDetector(
            onTap: _addedToCart ? null : _addToCart,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 58,
              decoration: BoxDecoration(
                gradient: _addedToCart
                    ? const LinearGradient(
                        colors: [Color(0xFF0F1923), Color(0xFF0F1923)])
                    : const LinearGradient(
                        colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
                borderRadius: BorderRadius.circular(18),
                border: _addedToCart
                    ? Border.all(
                        color: const Color(0xFF00D4FF), width: 1.5)
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _addedToCart
                        ? Icons.check_circle_rounded
                        : Icons.shopping_cart_rounded,
                    color: _addedToCart
                        ? const Color(0xFF00D4FF)
                        : Colors.black,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _addedToCart
                        ? "Ajouté au panier"
                        : "Ajouter au panier",
                    style: TextStyle(
                      color: _addedToCart
                          ? const Color(0xFF00D4FF)
                          : Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPriceRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required Color valueColor,
    required double fontSize,
    bool bold = false,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        const SizedBox(width: 14),
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _imagePlaceholder() {
    return Container(
      color: const Color(0xFF0F1923),
      child: const Center(
        child: Icon(Icons.shopping_bag_outlined,
            size: 80, color: Colors.white12),
      ),
    );
  }
}

// ============================================
// ECRAN PROFIL
// ============================================
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _addressCtrl;
  bool _saving = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl    = TextEditingController(text: UserProfile.name);
    _phoneCtrl   = TextEditingController(text: UserProfile.phone);
    _emailCtrl   = TextEditingController(text: UserProfile.email);
    _addressCtrl = TextEditingController(text: UserProfile.address);
    // Sync balance when profile screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBalance());
  }

  Future<void> _syncBalance() async {
    if (UserProfile.phone.trim().isEmpty) return;
    setState(() => _syncing = true);
    await UserProfile.syncBalance();
    if (mounted) setState(() => _syncing = false);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    UserProfile.name = _nameCtrl.text.trim();
    UserProfile.phone = _phoneCtrl.text.trim();
    UserProfile.email = _emailCtrl.text.trim();
    UserProfile.address = _addressCtrl.text.trim();
    await UserProfile.save();
    setState(() => _saving = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(children: [
          Icon(Icons.check_circle, color: Color(0xFF00D4FF)),
          SizedBox(width: 10),
          Text('Profil enregistré !', style: TextStyle(color: Colors.white)),
        ]),
        backgroundColor: const Color(0xFF0F1923),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF0F1923)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child:
                    const Icon(Icons.person_rounded, color: Colors.black),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mon Profil',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                  Text('Informations personnelles',
                      style:
                          TextStyle(color: Color(0xFF00D4FF), fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // Avatar
                Container(
                  width: 90,
                  height: 90,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                    ),
                  ),
                  child: Center(
                    child: Text(
                      UserProfile.name.isNotEmpty
                          ? UserProfile.name[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ).animate().scale(duration: 500.ms),

                // Balance card
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 24),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF00D4FF).withOpacity(0.12),
                        const Color(0xFF8B5CF6).withOpacity(0.06),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: const Color(0xFF00D4FF).withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF00D4FF).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                            Icons.account_balance_wallet_rounded,
                            color: Color(0xFF00D4FF),
                            size: 24),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Solde USDT',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                            const SizedBox(height: 4),
                            Text(
                              '${UserProfile.balance.toStringAsFixed(2)} USDT',
                              style: const TextStyle(
                                color: Color(0xFF00D4FF),
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '≈ ${(UserProfile.balance * EXCHANGE_RATE).toStringAsFixed(0)} DZD',
                              style: const TextStyle(
                                  color: Color(0xFF8B5CF6), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      // Refresh button
                      GestureDetector(
                        onTap: _syncing ? null : _syncBalance,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: _syncing
                              ? const SizedBox(
                                  key: ValueKey('spin'),
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF00D4FF),
                                  ),
                                )
                              : const Icon(
                                  key: ValueKey('icon'),
                                  Icons.refresh_rounded,
                                  color: Color(0xFF00D4FF),
                                  size: 24,
                                ),
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn(duration: 400.ms, delay: 100.ms),

                _buildField(
                  controller: _nameCtrl,
                  label: 'Nom complet',
                  hint: 'Ex: Ahmed Benali',
                  icon: Icons.person_outline,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Le nom est requis'
                      : null,
                ),
                const SizedBox(height: 16),
                _buildField(
                  controller: _phoneCtrl,
                  label: 'Numéro de téléphone',
                  hint: 'Ex: 0555 123 456',
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Le téléphone est requis'
                      : null,
                ),
                const SizedBox(height: 16),
                _buildField(
                  controller: _emailCtrl,
                  label: 'Email (optionnel)',
                  hint: 'Ex: ahmed@email.com',
                  icon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                _buildField(
                  controller: _addressCtrl,
                  label: 'Adresse de livraison',
                  hint: 'Ex: Rue des Martyrs, Alger',
                  icon: Icons.location_on_outlined,
                  maxLines: 2,
                ),
                const SizedBox(height: 32),

                // Info banner
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00D4FF).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: const Color(0xFF00D4FF).withOpacity(0.2)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.qr_code_2,
                          color: Color(0xFF00D4FF), size: 20),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Votre nom et téléphone seront intégrés dans le QR code afin que l\'agent identifie votre commande.',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 12, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // Save button
                SizedBox(
                  width: double.infinity,
                  child: GestureDetector(
                    onTap: _saving ? null : _save,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: _saving
                          ? const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.black,
                                ),
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.save_rounded,
                                    color: Colors.black, size: 22),
                                SizedBox(width: 10),
                                Text(
                                  'Enregistrer le profil',
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 17,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          keyboardType: keyboardType,
          maxLines: maxLines,
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.06),
            prefixIcon: Icon(icon, color: const Color(0xFF00D4FF), size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  BorderSide(color: Colors.white.withOpacity(0.08)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF00D4FF)),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Colors.redAccent, width: 1.5),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Colors.redAccent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================
// DRAPEAU ALGÉRIEN ANIMÉ
// ============================================
class AlgerianFlagPainter extends CustomPainter {
  final double wavePhase;
  final bool isMini;
  /// Y-axis spin angle for the diamond star (radians). Ignored when isMini.
  final double starPhase;

  AlgerianFlagPainter(this.wavePhase,
      {this.isMini = false, this.starPhase = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final paintGreen = Paint()..color = const Color(0xFF006233);
    final paintWhite = Paint()..color = Colors.white;
    final paintRed = Paint()..color = const Color(0xFFD21034);

    final double halfWidth = size.width / 2;
    final pathGreen = Path();
    final pathWhite = Path();

    final waveAmplitude = isMini ? 1.0 : 3.0;
    final waveFrequency = 0.05;

    pathGreen.moveTo(0, 0);
    for (double x = 0; x <= halfWidth; x++) {
      final y =
          sin((x * waveFrequency) + wavePhase) * waveAmplitude;
      pathGreen.lineTo(x, y);
    }
    for (double x = halfWidth; x >= 0; x--) {
      final y = size.height +
          sin((x * waveFrequency) + wavePhase + pi) * waveAmplitude;
      pathGreen.lineTo(x, y);
    }
    pathGreen.close();
    canvas.drawPath(pathGreen, paintGreen);

    pathWhite.moveTo(halfWidth, 0);
    for (double x = halfWidth; x <= size.width; x++) {
      final y =
          sin((x * waveFrequency) + wavePhase) * waveAmplitude;
      pathWhite.lineTo(x, y);
    }
    for (double x = size.width; x >= halfWidth; x--) {
      final y = size.height +
          sin((x * waveFrequency) + wavePhase + pi) * waveAmplitude;
      pathWhite.lineTo(x, y);
    }
    pathWhite.close();
    canvas.drawPath(pathWhite, paintWhite);

    final centerX = halfWidth;
    final centerY = size.height / 2;
    final crescentRadius = isMini ? 6.0 : 18.0;
    final starRadius = isMini ? 3.0 : 10.0;

    final crescentPath = Path();
    final outerRadius = crescentRadius;
    final innerRadius = crescentRadius * 0.7;
    final crescentOffset = crescentRadius * 0.3;

    crescentPath.addOval(Rect.fromCircle(
      center: Offset(centerX + crescentOffset, centerY),
      radius: outerRadius,
    ));
    crescentPath.addOval(Rect.fromCircle(
      center: Offset(
          centerX + crescentOffset + (outerRadius - innerRadius), centerY),
      radius: innerRadius,
    ));
    crescentPath.fillType = PathFillType.evenOdd;
    canvas.drawPath(crescentPath, paintRed);

    // ---- Static red 5-pointed star (background shape, always shown) ----
    final starPath = Path();
    const numPoints = 5;
    final outerR = starRadius;
    final innerR = starRadius * 0.4;
    final starCx = centerX - crescentRadius * 0.3;
    final starCy = centerY;

    for (int i = 0; i < numPoints * 2; i++) {
      final radius = i.isEven ? outerR : innerR;
      final angle = (i * pi / numPoints) - pi / 2;
      final x = starCx + radius * cos(angle);
      final y = starCy + radius * sin(angle);
      if (i == 0) {
        starPath.moveTo(x, y);
      } else {
        starPath.lineTo(x, y);
      }
    }
    starPath.close();
    canvas.drawPath(starPath, paintRed);

    // ---- Rotating 3-D diamond star (Y-axis flip, green ↔ red) ----
    if (!isMini) {
      final cosY = cos(starPhase);          // −1…+1 — determines face + width
      final isGreenFace = cosY >= 0;
      final scaleX = cosY.abs().clamp(0.05, 1.0); // apparent width

      final faceColor = isGreenFace
          ? const Color(0xFF00D4FF)   // brilliant green
          : const Color(0xFFFF1C35);  // brilliant red

      // faceColor used for both solid and glow — no separate variable needed

      // Glow behind the star
      final glowPaint = Paint()
        ..color = faceColor.withOpacity(0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

      // Solid face
      final facePaint = Paint()
        ..color = faceColor
        ..style = PaintingStyle.fill;

      // Thin bright edge highlight
      final edgePaint = Paint()
        ..color = Colors.white.withOpacity(0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6;

      final dR = starRadius * 0.9;   // outer tip radius of diamond star
      final dInner = dR * 0.22;      // inner notch radius (sharp diamond shape)

      Path _diamondPath() {
        final p = Path();
        for (int i = 0; i < 8; i++) {
          final r = i.isEven ? dR : dInner;
          // 45° offset so tips point N/E/S/W (diamond orientation)
          final a = (i * pi / 4) - pi / 4;
          final lx = r * cos(a) * scaleX;
          final ly = r * sin(a);
          if (i == 0) p.moveTo(lx, ly); else p.lineTo(lx, ly);
        }
        p.close();
        return p;
      }

      canvas.save();
      canvas.translate(starCx, starCy);   // centre on existing star position

      canvas.drawPath(_diamondPath(), glowPaint);
      canvas.drawPath(_diamondPath(), facePaint);
      canvas.drawPath(_diamondPath(), edgePaint);

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(AlgerianFlagPainter oldDelegate) => true;
}

// ============================================
// ROTATING STAR OVERLAY (drawn on top of flag image)
// ============================================
class _StarOverlayPainter extends CustomPainter {
  final double starPhase;
  _StarOverlayPainter(this.starPhase);

  @override
  void paint(Canvas canvas, Size size) {
    const crescentRadius = 18.0;
    const starRadius = 10.0;
    final starCx = size.width / 2 - crescentRadius * 0.3;
    final starCy = size.height / 2;

    final cosY = cos(starPhase);
    final isGreenFace = cosY >= 0;
    final scaleX = cosY.abs().clamp(0.05, 1.0);

    final faceColor = isGreenFace
        ? const Color(0xFF00D4FF)
        : const Color(0xFFFF1C35);

    final glowPaint = Paint()
      ..color = faceColor.withOpacity(0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final facePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    final edgePaint = Paint()
      ..color = Colors.white.withOpacity(0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    const dR = starRadius * 0.9;
    const dInner = dR * 0.22;

    Path diamondPath() {
      final p = Path();
      for (int i = 0; i < 8; i++) {
        final r = i.isEven ? dR : dInner;
        final a = (i * pi / 4) - pi / 4;
        final lx = r * cos(a) * scaleX;
        final ly = r * sin(a);
        if (i == 0) p.moveTo(lx, ly); else p.lineTo(lx, ly);
      }
      p.close();
      return p;
    }

    canvas.save();
    canvas.translate(starCx, starCy);
    canvas.drawPath(diamondPath(), glowPaint);
    canvas.drawPath(diamondPath(), facePaint);
    canvas.drawPath(diamondPath(), edgePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StarOverlayPainter oldDelegate) => true;
}
