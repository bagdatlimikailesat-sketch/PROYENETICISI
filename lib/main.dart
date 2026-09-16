import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await NotificationService.initialize();

  runApp(const ProAjandaApp());
}

// ======================================================
// BİLDİRİM SERVİSİ
// ======================================================

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _notifications.initialize(
      settings: initializationSettings,
    );

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    // Android 13+ için normal bildirim iznini ister.
    await androidPlugin?.requestNotificationsPermission();

    final iosPlugin = _notifications
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();

    // iOS'ta bildirim iznini ister.
    await iosPlugin?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  static Future<void> schedulePlan(Plan plan) async {
    if (plan.isCompleted) return;

    final scheduledDate = tz.TZDateTime(
      tz.local,
      plan.date.year,
      plan.date.month,
      plan.date.day,
      plan.date.hour,
      plan.date.minute,
    );

    final now = tz.TZDateTime.now(tz.local);

    if (!scheduledDate.isAfter(now)) {
      return;
    }

    const androidDetails = AndroidNotificationDetails(
      'proajanda_plans_v3',
      'Plan Hatırlatmaları',
      channelDescription: 'ProAjanda plan bildirimleri',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    // Exact alarm izni yoksa uygulama hata vermesin.
    // Önce tam zamanlı bildirim denenir, olmazsa yaklaşık zamanlı planlanır.
    try {
      await _notifications.zonedSchedule(
        id: plan.notificationId,
        title: 'ProAjanda',
        body: plan.note.trim().isEmpty
            ? plan.title
            : '${plan.title}\n${plan.note}',
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode:
            AndroidScheduleMode.exactAllowWhileIdle,
        payload: plan.id,
      );
    } catch (_) {
      await _notifications.zonedSchedule(
        id: plan.notificationId,
        title: 'ProAjanda',
        body: plan.note.trim().isEmpty
            ? plan.title
            : '${plan.title}\n${plan.note}',
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode:
            AndroidScheduleMode.inexactAllowWhileIdle,
        payload: plan.id,
      );
    }
  }

  static Future<void> cancel(int notificationId) async {
    await _notifications.cancel(
      id: notificationId,
    );
  }

  static Future<void> showTestNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'proajanda_test',
      'ProAjanda Test',
      channelDescription: 'ProAjanda bildirim testi',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _notifications.show(
      id: 999999,
      title: 'ProAjanda',
      body: 'Bildirim sistemi çalışıyor.',
      notificationDetails: details,
    );
  }
}

// ======================================================
// PLAN MODELİ
// ======================================================

class Plan {
  Plan({
    required this.id,
    required this.title,
    required this.note,
    required this.date,
    required this.notificationId,
    this.isCompleted = false,
  });

  final String id;
  final String title;
  final String note;
  final DateTime date;
  final int notificationId;
  bool isCompleted;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'note': note,
      'date': date.toIso8601String(),
      'notificationId': notificationId,
      'isCompleted': isCompleted,
    };
  }

  factory Plan.fromMap(Map<String, dynamic> map) {
    final parsedDate = DateTime.parse(map['date']);

    return Plan(
      id: map['id'] ??
          '${parsedDate.millisecondsSinceEpoch}_${map['title'] ?? ''}',
      title: map['title'] ?? '',
      note: map['note'] ?? '',
      date: parsedDate,
      notificationId: map['notificationId'] ??
          parsedDate.millisecondsSinceEpoch.remainder(2147483647),
      isCompleted: map['isCompleted'] ?? false,
    );
  }
}

// ======================================================
// ANA UYGULAMA
// ======================================================

class ProAjandaApp extends StatefulWidget {
  const ProAjandaApp({super.key});

  @override
  State<ProAjandaApp> createState() => _ProAjandaAppState();
}

class _ProAjandaAppState extends State<ProAjandaApp> {
  final List<Plan> plans = [];

  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadPlans();
  }

  Future<void> loadPlans() async {
    final prefs = await SharedPreferences.getInstance();
    final savedData = prefs.getString('plans');

    if (savedData != null) {
      try {
        final List<dynamic> decoded = jsonDecode(savedData);

        plans
          ..clear()
          ..addAll(
            decoded.map(
              (item) => Plan.fromMap(
                Map<String, dynamic>.from(item),
              ),
            ),
          );

        for (final plan in plans) {
          if (!plan.isCompleted && plan.date.isAfter(DateTime.now())) {
            await NotificationService.schedulePlan(plan);
          }
        }
      } catch (_) {
        // Eski/bozuk kayıt varsa uygulamanın açılmasını engelleme.
      }
    }

    if (mounted) {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> savePlans() async {
    final prefs = await SharedPreferences.getInstance();

    final encoded = jsonEncode(
      plans.map((plan) => plan.toMap()).toList(),
    );

    await prefs.setString('plans', encoded);
  }

  Future<void> addPlan(Plan plan) async {
    setState(() {
      plans.add(plan);
    });

    await savePlans();
    await NotificationService.schedulePlan(plan);
  }

  Future<void> updatePlan(
    int index,
    Plan newPlan,
  ) async {
    final oldPlan = plans[index];

    await NotificationService.cancel(
      oldPlan.notificationId,
    );

    setState(() {
      plans[index] = newPlan;
    });

    await savePlans();
    await NotificationService.schedulePlan(newPlan);
  }

  Future<void> deletePlan(int index) async {
    await NotificationService.cancel(
      plans[index].notificationId,
    );

    setState(() {
      plans.removeAt(index);
    });

    await savePlans();
  }

  Future<void> togglePlan(int index) async {
    final plan = plans[index];

    setState(() {
      plan.isCompleted = !plan.isCompleted;
    });

    if (plan.isCompleted) {
      await NotificationService.cancel(
        plan.notificationId,
      );
    } else {
      await NotificationService.schedulePlan(plan);
    }

    await savePlans();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ProAjanda',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
        ),
        useMaterial3: true,
      ),
      home: isLoading
          ? const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            )
          : HomePage(
              plans: plans,
              onAddPlan: addPlan,
              onUpdatePlan: updatePlan,
              onDeletePlan: deletePlan,
              onTogglePlan: togglePlan,
            ),
    );
  }
}

// ======================================================
// ANA SAYFA
// ======================================================

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.plans,
    required this.onAddPlan,
    required this.onUpdatePlan,
    required this.onDeletePlan,
    required this.onTogglePlan,
  });

  final List<Plan> plans;

  final Future<void> Function(Plan) onAddPlan;

  final Future<void> Function(
    int,
    Plan,
  ) onUpdatePlan;

  final Future<void> Function(int) onDeletePlan;

  final Future<void> Function(int) onTogglePlan;

  @override
  Widget build(BuildContext context) {
    final completedCount =
        plans.where((plan) => plan.isCompleted).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ProAjanda',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 30),

            const Icon(
              Icons.calendar_month_rounded,
              size: 80,
              color: Color(0xFF6750A4),
            ),

            const SizedBox(height: 20),

            const Text(
              'Planlarını Kolayca Yönet',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 12),

            Text(
              plans.isEmpty
                  ? 'Henüz planın yok.'
                  : '${plans.length} plan • '
                      '$completedCount tamamlandı',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),

            const SizedBox(height: 40),

            ElevatedButton.icon(
              onPressed: () async {
                final newPlan = await Navigator.push<Plan>(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        const PlanEditorPage(),
                  ),
                );

                if (newPlan != null) {
                  await onAddPlan(newPlan);

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Plan kaydedildi. Bildirim ayarlandı.',
                        ),
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Yeni Plan Oluştur'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                ),
              ),
            ),

            const SizedBox(height: 15),

            OutlinedButton.icon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PlansPage(
                      plans: plans,
                      onUpdatePlan: onUpdatePlan,
                      onDeletePlan: onDeletePlan,
                      onTogglePlan: onTogglePlan,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.list_alt),
              label: const Text('Planlarımı Gör'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// PLAN EKLEME / DÜZENLEME
// ======================================================

class PlanEditorPage extends StatefulWidget {
  const PlanEditorPage({
    super.key,
    this.plan,
  });

  final Plan? plan;

  @override
  State<PlanEditorPage> createState() =>
      _PlanEditorPageState();
}

class _PlanEditorPageState
    extends State<PlanEditorPage> {
  late final TextEditingController planController;
  late final TextEditingController noteController;

  late DateTime selectedDate;
  late TimeOfDay selectedTime;

  bool get isEditing => widget.plan != null;

  @override
  void initState() {
    super.initState();

    final existingPlan = widget.plan;

    planController = TextEditingController(
      text: existingPlan?.title ?? '',
    );

    noteController = TextEditingController(
      text: existingPlan?.note ?? '',
    );

    if (existingPlan != null) {
      selectedDate = existingPlan.date;

      selectedTime = TimeOfDay(
        hour: existingPlan.date.hour,
        minute: existingPlan.date.minute,
      );
    } else {
      final defaultDate =
          DateTime.now().add(const Duration(minutes: 5));

      selectedDate = defaultDate;

      selectedTime = TimeOfDay(
        hour: defaultDate.hour,
        minute: defaultDate.minute,
      );
    }
  }

  Future<void> selectDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (selected != null) {
      setState(() {
        selectedDate = selected;
      });
    }
  }

  Future<void> selectTime() async {
    final selected = await showTimePicker(
      context: context,
      initialTime: selectedTime,
    );

    if (selected != null) {
      setState(() {
        selectedTime = selected;
      });
    }
  }

  void savePlan() {
    final title = planController.text.trim();
    final note = noteController.text.trim();

    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Lütfen plan adını girin.',
          ),
        ),
      );

      return;
    }

    final fullDate = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    if (!fullDate.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Bildirim için ileri bir tarih ve saat seçin.',
          ),
        ),
      );

      return;
    }

    final oldPlan = widget.plan;
    final nowId = DateTime.now().millisecondsSinceEpoch;

    final plan = Plan(
      id: oldPlan?.id ?? nowId.toString(),
      title: title,
      note: note,
      date: fullDate,
      notificationId:
          oldPlan?.notificationId ??
              nowId.remainder(2147483647),
      isCompleted:
          oldPlan?.isCompleted ?? false,
    );

    Navigator.pop(context, plan);
  }

  @override
  void dispose() {
    planController.dispose();
    noteController.dispose();

    super.dispose();
  }

  String twoDigits(int number) {
    return number.toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isEditing
              ? 'Planı Düzenle'
              : 'Yeni Plan Oluştur',
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: planController,
              decoration: const InputDecoration(
                labelText: 'Plan adı',
                prefixIcon: Icon(Icons.edit_note),
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 16),

            TextField(
              controller: noteController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Not',
                prefixIcon: Icon(Icons.notes),
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 16),

            InkWell(
              onTap: selectDate,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Tarih',
                  prefixIcon: Icon(
                    Icons.calendar_today,
                  ),
                  border: OutlineInputBorder(),
                ),
                child: Text(
                  '${twoDigits(selectedDate.day)}.'
                  '${twoDigits(selectedDate.month)}.'
                  '${selectedDate.year}',
                ),
              ),
            ),

            const SizedBox(height: 16),

            InkWell(
              onTap: selectTime,
              borderRadius: BorderRadius.circular(12),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Saat',
                  prefixIcon: Icon(
                    Icons.access_time,
                  ),
                  border: OutlineInputBorder(),
                ),
                child: Text(
                  '${twoDigits(selectedTime.hour)}:'
                  '${twoDigits(selectedTime.minute)}',
                ),
              ),
            ),

            const SizedBox(height: 25),

            ElevatedButton.icon(
              onPressed: savePlan,
              icon: Icon(
                isEditing
                    ? Icons.check
                    : Icons.save,
              ),
              label: Text(
                isEditing
                    ? 'Değişiklikleri Kaydet'
                    : 'Planı Kaydet',
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// PLANLARIM
// ======================================================

class PlansPage extends StatefulWidget {
  const PlansPage({
    super.key,
    required this.plans,
    required this.onUpdatePlan,
    required this.onDeletePlan,
    required this.onTogglePlan,
  });

  final List<Plan> plans;

  final Future<void> Function(
    int,
    Plan,
  ) onUpdatePlan;

  final Future<void> Function(int) onDeletePlan;

  final Future<void> Function(int) onTogglePlan;

  @override
  State<PlansPage> createState() =>
      _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  String twoDigits(int number) {
    return number.toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Planlarım'),
      ),
      body: widget.plans.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.event_note,
                    size: 70,
                    color: Colors.grey,
                  ),
                  SizedBox(height: 15),
                  Text(
                    'Henüz kayıtlı plan yok',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(15),
              itemCount: widget.plans.length,
              itemBuilder: (context, index) {
                final plan = widget.plans[index];

                return Card(
                  margin: const EdgeInsets.only(
                    bottom: 12,
                  ),
                  child: ListTile(
                    leading: Checkbox(
                      value: plan.isCompleted,
                      onChanged: (_) async {
                        await widget.onTogglePlan(index);

                        if (mounted) {
                          setState(() {});
                        }
                      },
                    ),

                    title: Text(
                      plan.title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        decoration: plan.isCompleted
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),

                    subtitle: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        if (plan.note.isNotEmpty)
                          Text(plan.note),

                        const SizedBox(height: 5),

                        Row(
                          children: [
                            const Icon(
                              Icons.calendar_today,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${twoDigits(plan.date.day)}.'
                              '${twoDigits(plan.date.month)}.'
                              '${plan.date.year}',
                            ),
                            const SizedBox(width: 12),
                            const Icon(
                              Icons.access_time,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${twoDigits(plan.date.hour)}:'
                              '${twoDigits(plan.date.minute)}',
                            ),
                          ],
                        ),
                      ],
                    ),

                    trailing: PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'edit') {
                          final edited =
                              await Navigator.push<Plan>(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  PlanEditorPage(
                                plan: plan,
                              ),
                            ),
                          );

                          if (edited != null) {
                            await widget.onUpdatePlan(
                              index,
                              edited,
                            );

                            if (mounted) {
                              setState(() {});

                              ScaffoldMessenger.of(context)
                                  .showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Plan güncellendi',
                                  ),
                                ),
                              );
                            }
                          }
                        }

                        if (value == 'delete') {
                          await widget.onDeletePlan(index);

                          if (mounted) {
                            setState(() {});

                            ScaffoldMessenger.of(context)
                                .showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Plan silindi',
                                ),
                              ),
                            );
                          }
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit),
                              SizedBox(width: 8),
                              Text('Düzenle'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline,
                              ),
                              SizedBox(width: 8),
                              Text('Sil'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
