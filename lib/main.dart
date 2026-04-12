import 'dart:ui';
import 'dart:math';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:screenshot/screenshot.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';

// ============================================
// CONFIGURATION
// ============================================
const String OPENROUTER_API_KEY = String.fromEnvironment('OPENROUTER_API_KEY');
const String OPENROUTER_MODEL = 'google/gemma-2-9b-it';
const String OPENROUTER_VISION_MODEL = 'google/gemini-flash-1.5';
const String VPS_SERVER_IP = '76.13.255.239'; // Remplace par ton IP VPS
const double EXCHANGE_RATE = 242.0;

void main() {
  if (OPENROUTER_API_KEY.isEmpty) {
    debugPrint('WARNING: OPENROUTER_API_KEY is not set. Build with --dart-define=OPENROUTER_API_KEY=your_key');
  }
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
      title: 'henini',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0A0E21),
        primaryColor: const Color(0xFF00FF87),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00FF87),
          brightness: Brightness.dark,
        ),
        fontFamily: 'SF Pro Display',
      ),
      home: const MainScreen(),
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

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  int _currentIndex = 0;
  
  final List<Widget> _screens = [
    const HomeScreen(),
    const AIScreen(),
    const HistoryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF1A1F3D),
              const Color(0xFF0A0E21),
            ],
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
          selectedItemColor: const Color(0xFF00FF87),
          unselectedItemColor: Colors.white38,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: 'Accueil',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.smart_toy_rounded),
              label: 'IA',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history_rounded),
              label: 'Historique',
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
  bool _isAnalyzing = false;
  bool _isPickingImage = false;
  double _originalPrice = 0.0;
  double _totalUsdt = 0.0;
  double _totalDzd = 0.0;
  String _orderID = "";
  String _productName = "";
  String _productImage = "";
  String _aiAdvice = "";
  Uint8List? _pickedImageBytes;
  
  late AnimationController _flagController;
  late Animation<double> _flagAnimation;

  @override
  void initState() {
    super.initState();
    _flagController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _flagAnimation = Tween<double>(begin: 0, end: 2 * pi).animate(_flagController);
  }

  @override
  void dispose() {
    _flagController.dispose();
    _linkController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  // --- SCRAPER VPS ---
  Future<void> _fetchPriceFromScraper() async {
    String url = _linkController.text.trim();
    if (url.isEmpty) {
      _showToast("Veuillez entrer un lien produit");
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await http.get(
        Uri.parse('http://$VPS_SERVER_IP:3000/browse?url=${Uri.encodeComponent(url)}')
      ).timeout(const Duration(seconds: 60));

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

  // Auto-fetch when user pastes/types an AliExpress URL
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
      _totalUsdt = _originalPrice * 1.25;
      _totalDzd = _totalUsdt * EXCHANGE_RATE;
      _orderID = "TC-${Random().nextInt(9000) + 1000}";
    });
  }

  // --- ANALYSE IA ---
  Future<void> _analyzeWithAI() async {
    if (_productName.isEmpty && _linkController.text.isEmpty) {
      _showToast("Scannez d'abord un produit");
      return;
    }
    
    setState(() => _isAnalyzing = true);
    
    try {
      final response = await http.post(
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $OPENROUTER_API_KEY',
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://tchipa.app',
        },
        body: json.encode({
          'model': OPENROUTER_MODEL,
          'messages': [
            {
              'role': 'system',
              'content': '''Tu es un expert en e-commerce spécialisé dans l'analyse de produits AliExpress et Temu.
              Tu aides les acheteurs algériens à faire les bons choix.
              Réponds de manière concise et en français.
              Donne des conseils sur:
              - La fiabilité du prix
              - La qualité attendue
              - Les points à vérifier avant d'acheter
              - Les questions à poser au vendeur'''
            },
            {
              'role': 'user',
              'content': 'Analyse ce produit: $_productName\nPrix: \$$_originalPrice\nLien: ${_linkController.text}'
            }
          ],
          'max_tokens': 500,
          'temperature': 0.7,
        }),
      ).timeout(const Duration(seconds: 45));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _aiAdvice = data['choices'][0]['message']['content'] ?? 'Pas de conseil disponible';
        });
        _showAIAdviceDialog();
      } else {
        debugPrint('OpenRouter error [analyzeWithAI]: ${response.statusCode} ${response.body}');
        String errorMsg;
        if (response.statusCode == 401) {
          errorMsg = "Clé API invalide ou manquante";
        } else if (response.statusCode == 404) {
          errorMsg = "Modèle IA introuvable (404)";
        } else if (response.statusCode == 429) {
          errorMsg = "Limite de requêtes atteinte, réessayez plus tard";
        } else if (response.statusCode == 402) {
          errorMsg = "Crédits OpenRouter épuisés";
        } else {
          errorMsg = "Erreur IA: ${response.statusCode}";
        }
        _showToast(errorMsg);
      }
    } catch (e) {
      debugPrint('OpenRouter exception [analyzeWithAI]: $e');
      _showToast("Erreur de connexion IA: $e");
    } finally {
      setState(() => _isAnalyzing = false);
    }
  }

  // --- ANALYSE IMAGE (VISION) ---
  Future<void> _pickImageAndAnalyze() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    setState(() {
      _pickedImageBytes = bytes;
      _isPickingImage = true;
    });

    try {
      final base64Image = base64Encode(bytes);
      final response = await http.post(
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $OPENROUTER_API_KEY',
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://tchipa.app',
        },
        body: json.encode({
          'model': OPENROUTER_VISION_MODEL,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/jpeg;base64,$base64Image',
                  },
                },
                {
                  'type': 'text',
                  'text':
                      'Analyse cette capture d\'écran de produit AliExpress ou Temu. '
                      'Extrais les informations suivantes:\n'
                      '1. Le nom du produit\n'
                      '2. Le prix en USD\n'
                      '3. L\'URL complète visible dans la barre d\'adresse ou sur la page (si présente)\n'
                      '4. L\'identifiant (item ID) du produit AliExpress: c\'est le nombre dans l\'URL '
                      'après "/item/" ou dans le paramètre "id=" (ex: https://www.aliexpress.com/item/1005006123456789.html → item_id = "1005006123456789")\n'
                      'Réponds UNIQUEMENT en JSON avec ce format exact: '
                      '{"name": "...", "price": 0.00, "url": "...", "item_id": "..."}. '
                      'Si une valeur est introuvable, utilise null pour ce champ.',
                },
              ],
            }
          ],
          'max_tokens': 400,
        }),
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final content = data['choices'][0]['message']['content'] as String;
        // Extract JSON from the response (model may wrap it in markdown)
        final jsonMatch = RegExp(r'\{.*\}', dotAll: true).firstMatch(content);
        if (jsonMatch != null) {
          final parsed = json.decode(jsonMatch.group(0)!);
          final extractedUrl = parsed['url']?.toString() ?? '';
          final extractedItemId = parsed['item_id']?.toString() ?? '';

          // If item_id not directly extracted, try to parse it from the URL
          String itemId = extractedItemId;
          if (itemId.isEmpty && extractedUrl.isNotEmpty) {
            final itemMatch = RegExp(r'/item/(\d+)').firstMatch(extractedUrl);
            itemId = itemMatch?.group(1) ?? '';
            if (itemId.isEmpty) {
              final idParam = RegExp(r'[?&]id=(\d+)').firstMatch(extractedUrl);
              itemId = idParam?.group(1) ?? '';
            }
          }

          setState(() {
            _productName = parsed['name']?.toString() ?? '';
            final price = parsed['price'];
            if (price != null) {
              _priceController.text = price.toString();
              _calculate();
            }
            if (extractedUrl.isNotEmpty && _linkController.text.isEmpty) {
              _linkController.text = extractedUrl;
            }
          });

          String toast = "Produit extrait depuis l'image !";
          if (itemId.isNotEmpty) toast += " (ID: $itemId)";
          _showToast(toast);
        } else {
          _showToast("Impossible d'extraire le produit. Réessayez.");
        }
      } else {
        debugPrint('OpenRouter vision error: ${response.statusCode} ${response.body}');
        String errorMsg;
        if (response.statusCode == 401) {
          errorMsg = "Clé API invalide ou manquante";
        } else if (response.statusCode == 404) {
          errorMsg = "Modèle vision introuvable (404)";
        } else if (response.statusCode == 429) {
          errorMsg = "Limite de requêtes atteinte, réessayez plus tard";
        } else if (response.statusCode == 402) {
          errorMsg = "Crédits OpenRouter épuisés";
        } else {
          errorMsg = "Erreur vision IA: ${response.statusCode}";
        }
        _showToast(errorMsg);
      }
    } catch (e) {
      debugPrint('Vision exception: $e');
      _showToast("Erreur d'analyse image: $e");
    } finally {
      setState(() => _isPickingImage = false);
    }
  }

  void _showAIAdviceDialog() {
    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A1F3D),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.smart_toy, color: Colors.black),
              ),
              const SizedBox(width: 12),
              const Text("Conseil IA", style: TextStyle(color: Colors.white)),
            ],
          ),
          content: SingleChildScrollView(
            child: Text(
              _aiAdvice,
              style: const TextStyle(color: Colors.white70, height: 1.6),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fermer", style: TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      ),
    );
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
          backgroundColor: const Color(0xFF1A1F3D),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
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
                        const Color(0xFF00FF87).withOpacity(0.1),
                        const Color(0xFF60EFFF).withOpacity(0.1),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // En-tête
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildMiniAlgerianFlag(),
                          const SizedBox(width: 10),
                          const Text(
                            "TCHIPA PAY",
                            style: TextStyle(
                              color: Color(0xFF00FF87),
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      // QR Code
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: QrImageView(
                          data: "TCHIPA|$_orderID|${_totalUsdt.toStringAsFixed(2)}|USDT",
                          version: QrVersions.auto,
                          size: 180,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Color(0xFF00FF87),
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      // Infos
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
                          color: Color(0xFF00FF87),
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
              child: const Text("Fermer", style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: _shareCoupon,
              icon: const Icon(Icons.share),
              label: const Text("Partager"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FF87),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
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
        [XFile.fromData(image, name: 'tchipa_coupon.png', mimeType: 'image/png')],
        text: 'TchipaPay - Commande $_orderID - ${_totalUsdt.toStringAsFixed(2)} USDT',
      );
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF1A1F3D),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
              Color(0xFF0A0E21),
              Color(0xFF1A1F3D),
              Color(0xFF0A0E21),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 10),
                // Header avec drapeau
                _buildHeader(),
                const SizedBox(height: 30),
                // Input card
                _buildInputCard(),
                const SizedBox(height: 20),
                // Produit card (si détecté)
                if (_productName.isNotEmpty) _buildProductCard(),
                // Result card
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
        // Drapeau algérien animé
        SizedBox(
          height: 60,
          width: 90,
          child: AnimatedBuilder(
            animation: _flagAnimation,
            builder: (context, child) {
              return CustomPaint(
                painter: AlgerianFlagPainter(_flagAnimation.value),
              );
            },
          ),
        ).animate().fadeIn(duration: 600.ms).slideY(begin: -0.3),
        const SizedBox(height: 15),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
          ).createShader(bounds),
          child: const Text(
            "TCHIPA",
            style: TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 4,
            ),
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 200.ms),
        const SizedBox(height: 5),
        Text(
          "Vérificateur de produits AliExpress & Temu",
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 14,
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 400.ms),
      ],
    );
  }

  Widget _buildMiniAlgerianFlag() {
    return SizedBox(
      height: 20,
      width: 30,
      child: AnimatedBuilder(
        animation: _flagAnimation,
        builder: (context, child) {
          return CustomPaint(
            painter: AlgerianFlagPainter(_flagAnimation.value, isMini: true),
          );
        },
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
              prefixIcon: const Icon(Icons.link, color: Color(0xFF00FF87)),
              suffixIcon: _isLoading
                  ? Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.all(12),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00FF87),
                      ),
                    )
                  : IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.search, color: Colors.black, size: 18),
                      ),
                      onPressed: _fetchPriceFromScraper,
                    ),
            ),
          ),
          const SizedBox(height: 12),
          // Bouton import screenshot galerie
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isPickingImage ? null : _pickImageAndAnalyze,
              icon: _isPickingImage
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF60EFFF)),
                    )
                  : const Icon(Icons.image_search, color: Color(0xFF60EFFF)),
              label: Text(
                _isPickingImage ? "Analyse en cours..." : "Importer un screenshot",
                style: const TextStyle(color: Color(0xFF60EFFF)),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF60EFFF), width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
            ),
          ),
          // Aperçu de l'image choisie
          if (_pickedImageBytes != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                _pickedImageBytes!,
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ],
          const SizedBox(height: 15),
          // Prix manuel
          TextField(
            controller: _priceController,
            style: const TextStyle(color: Colors.white, fontSize: 24),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
              prefixIcon: const Icon(Icons.attach_money, color: Color(0xFF00FF87)),
            ),
          ),
          const SizedBox(height: 15),
          // Bouton analyser IA
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isAnalyzing ? null : _analyzeWithAI,
              icon: _isAnalyzing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Icon(Icons.auto_awesome, color: Colors.black),
              label: Text(
                _isAnalyzing ? "Analyse en cours..." : "Analyser avec l'IA",
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FF87),
                padding: const EdgeInsets.all(16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
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
              const Color(0xFF00FF87).withOpacity(0.1),
              const Color(0xFF60EFFF).withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF00FF87).withOpacity(0.3)),
        ),
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shopping_bag, color: Color(0xFF00FF87), size: 20),
                const SizedBox(width: 8),
                const Text(
                  "Produit détecté",
                  style: TextStyle(
                    color: Color(0xFF00FF87),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right, color: Colors.white38, size: 20),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _productName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
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
                  colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.visibility_rounded, color: Colors.black, size: 16),
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
        // Prix card
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF00FF87).withOpacity(0.15),
                const Color(0xFF60EFFF).withOpacity(0.1),
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: const Color(0xFF00FF87).withOpacity(0.3)),
          ),
          padding: const EdgeInsets.all(25),
          child: Column(
            children: [
              // Prix original
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Prix original",
                    style: TextStyle(color: Colors.white.withOpacity(0.6)),
                  ),
                  Text(
                    "\$${_originalPrice.toStringAsFixed(2)}",
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              // Total USDT
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
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00FF87),
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
                                color: Color(0xFF00FF87),
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Icon(
                      Icons.trending_up,
                      color: const Color(0xFF00FF87),
                      size: 40,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              // Estimation DZD
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
                      color: Color(0xFF60EFFF),
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                "Taux: 1 USDT = $EXCHANGE_RATE DZD",
                style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.2),
        const SizedBox(height: 20),
        // Bouton générer QR
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _showCouponDialog,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: Ink(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
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
// ECRAN IA CHAT
// ============================================
class AIScreen extends StatefulWidget {
  const AIScreen({super.key});

  @override
  State<AIScreen> createState() => _AIScreenState();
}

class _AIScreenState extends State<AIScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true));
      _isLoading = true;
    });
    _messageController.clear();
    _scrollToBottom();
    
    try {
      final response = await http.post(
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $OPENROUTER_API_KEY',
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://tchipa.app',
        },
        body: json.encode({
          'model': OPENROUTER_MODEL,
          'messages': [
            {
              'role': 'system',
              'content': '''Tu es TchipaBot, un assistant IA spécialisé dans l'aide aux acheteurs algériens sur AliExpress et Temu.
              Tu réponds en français, de manière amicale et concise.
              Tu peux aider à:
              - Vérifier si un prix est correct
              - Conseiller sur la qualité des produits
              - Donner des astuces pour économiser
              - Expliquer comment éviter les arnaques
              - Suggérer des questions à poser aux vendeurs'''
            },
            ..._messages.map((m) => {
              'role': m.isUser ? 'user' : 'assistant',
              'content': m.text,
            }).toList(),
          ],
          'max_tokens': 800,
          'temperature': 0.8,
        }),
      ).timeout(const Duration(seconds: 45));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final aiResponse = data['choices'][0]['message']['content'];
        setState(() {
          _messages.add(ChatMessage(text: aiResponse, isUser: false));
        });
      } else {
        debugPrint('OpenRouter error [sendMessage]: ${response.statusCode} ${response.body}');
        String errorMsg;
        if (response.statusCode == 401) {
          errorMsg = "Clé API invalide ou manquante. Vérifiez la configuration.";
        } else if (response.statusCode == 429) {
          errorMsg = "Limite de requêtes atteinte. Réessayez dans quelques secondes.";
        } else if (response.statusCode == 402) {
          errorMsg = "Crédits OpenRouter épuisés.";
        } else {
          errorMsg = "Erreur ${response.statusCode}. Réessayez.";
        }
        setState(() {
          _messages.add(ChatMessage(text: errorMsg, isUser: false));
        });
      }
    } catch (e) {
      debugPrint('OpenRouter exception [sendMessage]: $e');
      setState(() {
        _messages.add(ChatMessage(
          text: "Erreur de connexion: $e",
          isUser: false,
        ));
      });
    } finally {
      setState(() => _isLoading = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0A0E21),
            Color(0xFF1A1F3D),
          ],
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
                    colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.smart_toy, color: Colors.black),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "TchipaBot IA",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "En ligne • Gratuit",
                    style: TextStyle(color: Color(0xFF00FF87), fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            // Messages
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                              ),
                              borderRadius: BorderRadius.circular(25),
                            ),
                            child: const Icon(
                              Icons.chat_bubble_outline,
                              color: Colors.black,
                              size: 40,
                            ),
                          ).animate().scale(duration: 600.ms),
                          const SizedBox(height: 20),
                          Text(
                            "Posez vos questions\nsur AliExpress & Temu",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 16,
                            ),
                          ).animate().fadeIn(delay: 300.ms),
                          const SizedBox(height: 30),
                          _buildQuickAction("Ce prix est-il correct ?"),
                          _buildQuickAction("Comment éviter les arnaques ?"),
                          _buildQuickAction("Conseils pour négocier"),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(15),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) => _buildMessageBubble(_messages[i]),
                    ),
            ),
            // Input
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                border: Border(
                  top: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: "Posez votre question...",
                        hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(25),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                      ),
                      borderRadius: BorderRadius.circular(25),
                    ),
                    child: IconButton(
                      onPressed: _isLoading ? null : _sendMessage,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Icon(Icons.send, color: Colors.black),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAction(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: GestureDetector(
        onTap: () {
          _messageController.text = text;
          _sendMessage();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Text(
            text,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ),
    ).animate().fadeIn(delay: 500.ms);
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(15),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          gradient: msg.isUser
              ? const LinearGradient(
                  colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                )
              : null,
          color: msg.isUser ? null : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          msg.text,
          style: TextStyle(
            color: msg.isUser ? Colors.black : Colors.white,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  ChatMessage({required this.text, required this.isUser});
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
          colors: [
            Color(0xFF0A0E21),
            Color(0xFF1A1F3D),
          ],
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
              Icon(
                Icons.history,
                size: 80,
                color: Colors.white.withOpacity(0.2),
              ),
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
    setState(() => _addedToCart = true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF00FF87)),
            SizedBox(width: 10),
            Text("Ajouté au panier !", style: TextStyle(color: Colors.white)),
          ],
        ),
        backgroundColor: const Color(0xFF1A1F3D),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      body: CustomScrollView(
        slivers: [
          // App bar avec image hero
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            backgroundColor: const Color(0xFF0A0E21),
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
                        // Gradient overlay bottom
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
                                  const Color(0xFF0A0E21),
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
                  // Nom produit
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

                  // Carte prix
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          const Color(0xFF1A1F3D),
                          const Color(0xFF0A0E21),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.08),
                      ),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildPriceRow(
                          icon: Icons.attach_money,
                          iconColor: Colors.white54,
                          label: "Prix USD",
                          value: "\$${widget.priceUSD.toStringAsFixed(2)}",
                          valueColor: Colors.white70,
                          fontSize: 16,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.currency_bitcoin,
                          iconColor: const Color(0xFF26A17B),
                          label: "USDT",
                          value: "${widget.priceUSDT.toStringAsFixed(2)} USDT",
                          valueColor: const Color(0xFF26A17B),
                          fontSize: 22,
                          bold: true,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.flag_rounded,
                          iconColor: const Color(0xFF006233),
                          label: "DZD",
                          value: "~ ${widget.priceDZD.toStringAsFixed(0)} دج",
                          valueColor: const Color(0xFF60EFFF),
                          fontSize: 22,
                          bold: true,
                        ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 500.ms, delay: 100.ms).slideY(begin: 0.15),

                  const SizedBox(height: 16),

                  // Note taux
                  Row(
                    children: [
                      const Icon(Icons.info_outline, size: 13, color: Colors.white24),
                      const SizedBox(width: 6),
                      Text(
                        "Taux indicatif · 1 USDT = $EXCHANGE_RATE DZD",
                        style: const TextStyle(color: Colors.white24, fontSize: 12),
                      ),
                    ],
                  ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                ],
              ),
            ),
          ),
        ],
      ),

      // Bouton panier flottant
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0E21),
          border: Border(
            top: BorderSide(color: Colors.white.withOpacity(0.06)),
          ),
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
                        colors: [Color(0xFF1A1F3D), Color(0xFF1A1F3D)],
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
                      ),
                borderRadius: BorderRadius.circular(18),
                border: _addedToCart
                    ? Border.all(color: const Color(0xFF00FF87), width: 1.5)
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
                        ? const Color(0xFF00FF87)
                        : Colors.black,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _addedToCart ? "Ajouté au panier" : "Ajouter au panier",
                    style: TextStyle(
                      color: _addedToCart
                          ? const Color(0xFF00FF87)
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
        Text(
          label,
          style: TextStyle(
            color: Colors.white54,
            fontSize: 14,
          ),
        ),
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
      color: const Color(0xFF1A1F3D),
      child: const Center(
        child: Icon(
          Icons.shopping_bag_outlined,
          size: 80,
          color: Colors.white12,
        ),
      ),
    );
  }
}

// ============================================
// DRAPEAU ALGÉRIEN ANIMÉ
// ============================================
class AlgerianFlagPainter extends CustomPainter {
  final double wavePhase;
  final bool isMini;
  
  AlgerianFlagPainter(this.wavePhase, {this.isMini = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paintGreen = Paint()..color = const Color(0xFF006233);
    final paintWhite = Paint()..color = Colors.white;
    final paintRed = Paint()..color = const Color(0xFFD21034);
    
    final double halfWidth = size.width / 2;
    final pathGreen = Path();
    final pathWhite = Path();
    
    // Effet vague
    final waveAmplitude = isMini ? 1.0 : 3.0;
    final waveFrequency = 0.05;
    
    // Partie verte (gauche)
    pathGreen.moveTo(0, 0);
    for (double x = 0; x <= halfWidth; x++) {
      final y = sin((x * waveFrequency) + wavePhase) * waveAmplitude;
      pathGreen.lineTo(x, y);
    }
    for (double x = halfWidth; x >= 0; x--) {
      final y = size.height + sin((x * waveFrequency) + wavePhase + pi) * waveAmplitude;
      pathGreen.lineTo(x, y);
    }
    pathGreen.close();
    canvas.drawPath(pathGreen, paintGreen);
    
    // Partie blanche (droite)
    pathWhite.moveTo(halfWidth, 0);
    for (double x = halfWidth; x <= size.width; x++) {
      final y = sin((x * waveFrequency) + wavePhase) * waveAmplitude;
      pathWhite.lineTo(x, y);
    }
    for (double x = size.width; x >= halfWidth; x--) {
      final y = size.height + sin((x * waveFrequency) + wavePhase + pi) * waveAmplitude;
      pathWhite.lineTo(x, y);
    }
    pathWhite.close();
    canvas.drawPath(pathWhite, paintWhite);
    
    // Croissant et étoile rouges
    final centerX = halfWidth;
    final centerY = size.height / 2;
    final crescentRadius = isMini ? 6.0 : 18.0;
    final starRadius = isMini ? 3.0 : 10.0;
    
    // Croissant
    final crescentPath = Path();
    final outerRadius = crescentRadius;
    final innerRadius = crescentRadius * 0.7;
    final crescentOffset = crescentRadius * 0.3;
    
    crescentPath.addOval(Rect.fromCircle(
      center: Offset(centerX + crescentOffset, centerY),
      radius: outerRadius,
    ));
    crescentPath.addOval(Rect.fromCircle(
      center: Offset(centerX + crescentOffset + (outerRadius - innerRadius), centerY),
      radius: innerRadius,
    ));
    crescentPath.fillType = PathFillType.evenOdd;
    canvas.drawPath(crescentPath, paintRed);
    
    // Étoile
    final starPath = Path();
    const numPoints = 5;
    final outerR = starRadius;
    final innerR = starRadius * 0.4;
    
    for (int i = 0; i < numPoints * 2; i++) {
      final radius = i.isEven ? outerR : innerR;
      final angle = (i * pi / numPoints) - pi / 2;
      final x = centerX - crescentRadius * 0.3 + radius * cos(angle);
      final y = centerY + radius * sin(angle);
      
      if (i == 0) {
        starPath.moveTo(x, y);
      } else {
        starPath.lineTo(x, y);
      }
    }
    starPath.close();
    canvas.drawPath(starPath, paintRed);
  }

  @override
  bool shouldRepaint(AlgerianFlagPainter oldDelegate) => true;
}
