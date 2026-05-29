/// The fixed taxonomy of personal-sound categories the wizard offers. These
/// double as the `category` payload on every personal prototype.
///
/// Phase 1's research found these categories carry essentially all the deaf/HoH
/// notification value across the literature (ProtoSound, AdaptiveSound,
/// SoundWatch) plus the assistive-tech category requirements for the App Store
/// / Play Store. "custom" is the escape valve for everything else.
class SoundCategory {
  const SoundCategory({
    required this.id,
    required this.label,
    required this.description,
    required this.suggestedLabel,
    required this.minRecommendedSamples,
  });

  final String id;
  final String label;
  final String description;
  final String suggestedLabel;
  final int minRecommendedSamples;

  static const doorbell = SoundCategory(
    id: 'doorbell',
    label: 'Doorbell',
    description: "Your home, office, or relative's doorbell.",
    suggestedLabel: 'Front door bell',
    minRecommendedSamples: 5,
  );
  static const knock = SoundCategory(
    id: 'knock',
    label: 'Knock',
    description: 'Knocks on a specific door — front, bedroom, office.',
    suggestedLabel: 'Front door knock',
    minRecommendedSamples: 5,
  );
  static const fireAlarm = SoundCategory(
    id: 'fire_alarm',
    label: 'Fire alarm',
    description: 'The fire alarm at this location. Test it monthly.',
    suggestedLabel: 'Fire alarm',
    minRecommendedSamples: 3,
  );
  static const smokeAlarm = SoundCategory(
    id: 'smoke_alarm',
    label: 'Smoke alarm',
    description: 'Your smoke detector — usually three short beeps.',
    suggestedLabel: 'Smoke alarm',
    minRecommendedSamples: 3,
  );
  static const name = SoundCategory(
    id: 'name',
    label: 'Your name spoken',
    description: 'Family or housemates calling your name.',
    suggestedLabel: 'My name',
    minRecommendedSamples: 5,
  );
  static const familyVoice = SoundCategory(
    id: 'family_voice',
    label: 'Family voice',
    description: 'A specific household member greeting you.',
    suggestedLabel: 'Mom calling out',
    minRecommendedSamples: 5,
  );
  static const appliance = SoundCategory(
    id: 'appliance',
    label: 'Appliance beep',
    description: 'Microwave, oven, washing machine, kettle whistle, etc.',
    suggestedLabel: 'Microwave done',
    minRecommendedSamples: 4,
  );
  static const custom = SoundCategory(
    id: 'custom',
    label: 'Custom',
    description: 'Anything else that matters to you.',
    suggestedLabel: '',
    minRecommendedSamples: 5,
  );

  static const all = <SoundCategory>[
    doorbell,
    knock,
    fireAlarm,
    smokeAlarm,
    name,
    familyVoice,
    appliance,
    custom,
  ];

  static SoundCategory fromId(String id) =>
      all.firstWhere((c) => c.id == id, orElse: () => custom);
}
