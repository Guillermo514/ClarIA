/**
 * Modelos de datos que usa la aplicación.
 * Reflejan las tablas y funciones de Supabase descritas en docs/base-de-datos.md.
 */

// --- Usuario -------------------------------------------------------------

export type RoleName = 'student' | 'teacher' | 'admin';

export type AcademicLevel = 'primaria' | 'secundaria' | 'preparatoria' | 'universidad' | 'otro';

export interface Profile {
  id: string;
  fullName: string;
  birthDate: string;
  institution: string | null;
  academicLevel: AcademicLevel | null;
  role: RoleName;
}

export interface SignUpData {
  fullName: string;
  birthDate: string;
  institution: string;
  academicLevel: AcademicLevel | '';
  email: string;
  password: string;
}

// --- Niveles y lecciones --------------------------------------------------

/** Fila de la función get_my_levels(). */
export interface LevelSummary {
  id: string;
  levelNumber: number;
  title: string;
  objective: string;
  ageGroupCode: string;
  ageGroupName: string;
  unlocked: boolean;
  passed: boolean;
  bestScore: number | null;
  lessonsTotal: number;
  lessonsCompleted: number;
  gamesTotal: number;
  gamesCompleted: number;
  flashcardsTotal: number;
  flashcardsSeen: number;
  /** Ya completó lecciones, juegos y flashcards (o es docente/admin). */
  quizReady: boolean;
  medalName: string | null;
  medalIcon: string | null;
  medalEarned: boolean;
}

export interface LessonSummary {
  id: string;
  code: string;
  title: string;
  sortOrder: number;
  durationMin: number | null;
  hasGame: boolean;
  completed: boolean;
}

export interface LessonActivity {
  id: string;
  title: string;
  embedUrl: string;
  completed: boolean;
}

/** Respuesta de start_lesson() / start_activity(): tiempo que falta según el servidor. */
export interface TimedStart {
  completed: boolean;
  secondsRemaining: number;
}

export interface SourceLink {
  citation: string;
  url: string;
}

export interface LessonDetail extends LessonSummary {
  content: string;
  courseId: string;
  levelNumber: number;
  levelTitle: string;
  activities: LessonActivity[];
  articleId: string | null;
  articleTitle: string | null;
  /** true si ya lo marcó como leído (o si la lección no tiene artículo). */
  articleRead: boolean;
  cardsTotal: number;
  cardsSeen: number;
  /** Misión del evaluador obligatoria en esta lección (5.4 y 7.1). */
  mission: { id: string; title: string; passed: boolean } | null;
  source: SourceLink | null;
}

// --- Recursos -------------------------------------------------------------

export interface Article {
  id: string;
  title: string;
  summary: string;
  body: string;
  author: string;
  publishedLabel: string | null;
  lessonCode: string;
  lessonTitle: string;
  levelNumber: number;
  source: SourceLink | null;
  read: boolean;
}

/** Estado de las tarjetas del estudiante en un nivel. */
export interface CardStates {
  seenIds: string[];
  masteredIds: string[];
}

export interface Flashcard {
  id: string;
  front: string;
  back: string;
  lessonCode: string;
  lessonTitle: string;
}

// --- Evaluaciones ---------------------------------------------------------

export interface QuizOption {
  id: string;
  text: string;
}

export interface QuizQuestion {
  id: string;
  statement: string;
  options: QuizOption[];
}

export interface Quiz {
  id: string;
  title: string;
  passingScore: number;
  questions: QuizQuestion[];
}

export interface QuizAnswer {
  questionId: string;
  optionIds: string[];
}

/** Respuesta de la función submit_quiz(). */
export interface QuizResult {
  score: number;
  passed: boolean;
  correct: number;
  total: number;
  passingScore: number;
  results: { questionId: string; correct: boolean; correctOptionIds: string[] }[];
  newMedal: { name: string; icon: string | null } | null;
}

// --- Evaluador de prompts ------------------------------------------------

export type CriterionLevel = 'strong' | 'partial' | 'missing';
export type PromptRubric = 'basica' | 'avanzada';

/** Campo del constructor guiado (un ingrediente del prompt). */
export interface PromptField {
  key: string;
  label: string;
  description: string;
  minWords: number;
}

/** Textos de los campos, por clave (rol, contexto, tarea, formato, ejemplo, tecnicas). */
export type PromptFields = Record<string, string>;

export interface CheckResult {
  label: string;
  ok: boolean;
}

/** Resultado de evaluate_guided_prompt() / submit_prompt_attempt(). */
export interface PromptEvaluation {
  score: number;
  rubric: PromptRubric;
  words: number;
  composed: string;
  criteria: {
    key: string;
    label: string;
    description: string;
    weight: number;
    points: number;
    level: CriterionLevel;
    feedback: string;
    checks: CheckResult[];
    requirements: CheckResult[];
    /** Términos de la misión que se encontraron en el campo. */
    evidence: string[];
    /** false para criterios que no son un campo (Eficiencia). */
    guided: boolean;
  }[];
  penalties: { label: string; points: number; tip: string }[];
  requirementsMet: number;
  requirementsTotal: number;
  /** El prompt no corresponde a la misión (puntaje limitado a 40). */
  offTopic: boolean;
  message: string;
  /** Solo al enviar un intento de misión. */
  attemptNo?: number;
  passed?: boolean;
}

export interface MissionAttempt {
  attemptNo: number;
  score: number;
  /** Puntaje corregido por un docente, si lo revisó. */
  reviewedScore: number | null;
  reviewNote: string | null;
  passed: boolean;
  promptText: string;
  createdAt: string;
}

/** Misión del evaluador (tabla scenarios). */
export interface Mission {
  id: string;
  title: string;
  goal: string;
  passingScore: number;
  rubric: PromptRubric;
  ageGroupCode: string;
  ageGroupName: string;
  /** Lección en la que es obligatoria (p. ej. "5.4"), si aplica. */
  lessonCode: string | null;
  levelNumber: number | null;
  /** Lo que pide la misión en cada campo. */
  requirements: { field: string; label: string }[];
  attempts: MissionAttempt[];
  passed: boolean;
  bestScore: number | null;
}

/** Intento visto por un docente en la página de revisión. */
export interface AttemptForReview {
  id: string;
  studentName: string;
  missionTitle: string;
  lessonCode: string | null;
  attemptNo: number;
  score: number;
  reviewedScore: number | null;
  reviewNote: string | null;
  passed: boolean;
  promptText: string;
  createdAt: string;
}
