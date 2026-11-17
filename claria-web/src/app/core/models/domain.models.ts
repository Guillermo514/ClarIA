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
