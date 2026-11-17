import { Injectable, computed, effect, inject, signal } from '@angular/core';

import { AuthService } from '../auth/auth.service';
import {
  Article,
  Flashcard,
  LessonDetail,
  LessonSummary,
  LevelSummary,
  Quiz,
  QuizAnswer,
  QuizResult,
  SourceLink,
} from '../models/domain.models';
import { SupabaseService } from '../supabase/supabase.service';

/* Filas tal como llegan de Supabase (snake_case). */
interface LevelRow {
  id: string;
  level_number: number;
  title: string;
  objective: string;
  age_group_code: string;
  age_group_name: string;
  unlocked: boolean;
  passed: boolean;
  best_score: number | null;
  lessons_total: number;
  lessons_completed: number;
  medal_name: string | null;
  medal_icon: string | null;
  medal_earned: boolean;
}

interface SourceRow {
  sources: { citation: string; url: string } | null;
}

/** Primera fuente de un artículo (cada artículo del plan cita una). */
function firstSource(rows: SourceRow[] | null | undefined): SourceLink | null {
  const source = rows?.find((row) => row.sources)?.sources;
  return source ? { citation: source.citation, url: source.url } : null;
}

/**
 * Acceso al contenido del Plan Curricular y al progreso del estudiante.
 * Toda la lógica sensible (desbloqueo, calificación, medallas) vive en la base de datos.
 */
@Injectable({ providedIn: 'root' })
export class ContentService {
  private readonly supabase = inject(SupabaseService).client;
  private readonly auth = inject(AuthService);

  /** Niveles del grupo de edad del usuario, compartidos por todas las páginas. */
  readonly levels = signal<LevelSummary[]>([]);
  readonly levelsLoaded = signal(false);

  /** Nivel en curso: el primero desbloqueado que aún no se aprueba (o el último). */
  readonly currentLevel = computed(() => {
    const levels = this.levels();
    return levels.find((level) => level.unlocked && !level.passed) ?? levels.at(-1) ?? null;
  });

  constructor() {
    // Al cambiar de usuario (o cerrar sesión) se descarta la información del anterior.
    effect(() => {
      this.auth.session()?.user.id;
      this.levels.set([]);
      this.levelsLoaded.set(false);
    });
  }

  // --- Niveles --------------------------------------------------------------

  async refreshLevels(): Promise<LevelSummary[]> {
    const { data, error } = await this.supabase.rpc('get_my_levels');
    if (error) throw error;

    const levels = ((data ?? []) as LevelRow[]).map((row) => ({
      id: row.id,
      levelNumber: row.level_number,
      title: row.title,
      objective: row.objective,
      ageGroupCode: row.age_group_code,
      ageGroupName: row.age_group_name,
      unlocked: row.unlocked,
      passed: row.passed,
      bestScore: row.best_score === null ? null : Number(row.best_score),
      lessonsTotal: row.lessons_total,
      lessonsCompleted: row.lessons_completed,
      medalName: row.medal_name,
      medalIcon: row.medal_icon,
      medalEarned: row.medal_earned,
    }));
    this.levels.set(levels);
    this.levelsLoaded.set(true);
    return levels;
  }

  /** Niveles ya cargados o, si aún no, los pide. */
  async ensureLevels(): Promise<LevelSummary[]> {
    return this.levelsLoaded() ? this.levels() : this.refreshLevels();
  }

  async getLevel(levelNumber: number): Promise<LevelSummary | null> {
    const levels = await this.ensureLevels();
    return levels.find((level) => level.levelNumber === levelNumber) ?? null;
  }

  // --- Lecciones ------------------------------------------------------------

  async getLessons(courseId: string): Promise<LessonSummary[]> {
    const [{ data, error }, completed] = await Promise.all([
      this.supabase
        .from('lessons')
        .select('id, code, title, sort_order, duration_min, type')
        .eq('course_id', courseId)
        .order('sort_order'),
      this.completedLessonIds(),
    ]);
    if (error) throw error;

    return (data ?? []).map((row) => ({
      id: row.id,
      code: row.code,
      title: row.title,
      sortOrder: row.sort_order,
      durationMin: row.duration_min,
      hasGame: row.type === 'practice',
      completed: completed.has(row.id),
    }));
  }

  async getLesson(code: string): Promise<LessonDetail | null> {
    const [{ data, error }, completed] = await Promise.all([
      this.supabase
        .from('lessons')
        .select(
          `id, code, title, content, sort_order, duration_min, type, course_id,
           courses(level_number, title),
           lesson_activities(id, title, embed_url, sort_order),
           articles(title, article_sources(sources(citation, url)))`,
        )
        .eq('code', code)
        .maybeSingle(),
      this.completedLessonIds(),
    ]);
    if (error) throw error;
    if (!data) return null;

    const course = data.courses as unknown as { level_number: number; title: string };
    const articles = data.articles as unknown as { title: string; article_sources: SourceRow[] }[];
    const activities = [...(data.lesson_activities ?? [])].sort(
      (a, b) => a.sort_order - b.sort_order,
    );

    return {
      id: data.id,
      code: data.code,
      title: data.title,
      content: data.content,
      sortOrder: data.sort_order,
      durationMin: data.duration_min,
      hasGame: data.type === 'practice',
      completed: completed.has(data.id),
      courseId: data.course_id,
      levelNumber: course.level_number,
      levelTitle: course.title,
      activities: activities.map((a) => ({ id: a.id, title: a.title, embedUrl: a.embed_url })),
      articleTitle: articles[0]?.title ?? null,
      source: firstSource(articles[0]?.article_sources),
    };
  }

  /** Marca la lección como completada (la base de datos verifica que el nivel esté desbloqueado). */
  async completeLesson(lessonId: string): Promise<void> {
    const userId = this.requireUser();
    const now = new Date().toISOString();
    const { error } = await this.supabase.from('lesson_progress').upsert({
      user_id: userId,
      lesson_id: lessonId,
      status: 'completed',
      completed_at: now,
      last_activity_at: now,
    });
    if (error) throw error;
    void this.refreshLevels();
  }

  // --- Artículos ------------------------------------------------------------

  async getArticles(courseIds: string[]): Promise<Article[]> {
    if (!courseIds.length) return [];
    const { data, error } = await this.supabase
      .from('articles')
      .select(
        `id, title, summary, body, author, published_label,
         lessons!inner(code, title, sort_order, course_id, courses(level_number)),
         article_sources(sources(citation, url))`,
      )
      .in('lessons.course_id', courseIds);
    if (error) throw error;

    return (data ?? [])
      .map((row) => {
        const lesson = row.lessons as unknown as {
          code: string;
          title: string;
          sort_order: number;
          courses: { level_number: number };
        };
        return {
          id: row.id,
          title: row.title,
          summary: row.summary,
          body: row.body,
          author: row.author,
          publishedLabel: row.published_label,
          lessonCode: lesson.code,
          lessonTitle: lesson.title,
          levelNumber: lesson.courses.level_number,
          source: firstSource(row.article_sources as unknown as SourceRow[]),
          order: lesson.courses.level_number * 100 + lesson.sort_order,
        };
      })
      .sort((a, b) => a.order - b.order)
      .map(({ order: _order, ...article }) => article);
  }

  // --- Flashcards -----------------------------------------------------------

  async getFlashcards(courseId: string): Promise<Flashcard[]> {
    const { data, error } = await this.supabase
      .from('flashcards')
      .select('id, front, back, sort_order, lessons!inner(code, title, sort_order, course_id)')
      .eq('lessons.course_id', courseId);
    if (error) throw error;

    return (data ?? [])
      .map((row) => {
        const lesson = row.lessons as unknown as {
          code: string;
          title: string;
          sort_order: number;
        };
        return {
          id: row.id,
          front: row.front,
          back: row.back,
          lessonCode: lesson.code,
          lessonTitle: lesson.title,
          order: lesson.sort_order * 100 + row.sort_order,
        };
      })
      .sort((a, b) => a.order - b.order)
      .map(({ order: _order, ...card }) => card);
  }

  /** Ids de las tarjetas que el estudiante ya domina (caja 5 del repaso). */
  async getMasteredCardIds(cardIds: string[]): Promise<string[]> {
    if (!cardIds.length) return [];
    const { data, error } = await this.supabase
      .from('flashcard_reviews')
      .select('card_id')
      .in('card_id', cardIds)
      .eq('box', 5);
    if (error) throw error;
    return (data ?? []).map((row) => row.card_id);
  }

  async setCardMastered(cardId: string): Promise<void> {
    const { error } = await this.supabase.from('flashcard_reviews').upsert({
      user_id: this.requireUser(),
      card_id: cardId,
      box: 5,
      next_review_at: new Date().toISOString(),
    });
    if (error) throw error;
  }

  // --- Evaluaciones ---------------------------------------------------------

  /** Evaluación final del nivel. Las opciones llegan sin saber cuál es la correcta. */
  async getQuiz(courseId: string): Promise<Quiz | null> {
    const { data, error } = await this.supabase
      .from('quizzes')
      .select(
        `id, title, passing_score,
         questions(id, statement, sort_order, question_options(id, option_text, sort_order))`,
      )
      .eq('course_id', courseId)
      .maybeSingle();
    if (error) throw error;
    if (!data) return null;

    return {
      id: data.id,
      title: data.title,
      passingScore: Number(data.passing_score),
      questions: [...(data.questions ?? [])]
        .sort((a, b) => a.sort_order - b.sort_order)
        .map((q) => ({
          id: q.id,
          statement: q.statement,
          options: [...(q.question_options ?? [])]
            .sort((a, b) => a.sort_order - b.sort_order)
            .map((o) => ({ id: o.id, text: o.option_text })),
        })),
    };
  }

  /** Califica en el servidor, guarda el intento y, si aprueba, otorga la medalla. */
  async submitQuiz(quizId: string, answers: QuizAnswer[]): Promise<QuizResult> {
    const { data, error } = await this.supabase.rpc('submit_quiz', {
      p_quiz_id: quizId,
      p_answers: answers.map((a) => ({ question_id: a.questionId, option_ids: a.optionIds })),
    });
    if (error) throw error;

    const raw = data as {
      score: number;
      passed: boolean;
      correct: number;
      total: number;
      passing_score: number;
      results: { question_id: string; correct: boolean; correct_option_ids: string[] }[];
      new_medal: { name: string; icon: string | null } | null;
    };
    void this.refreshLevels();

    return {
      score: Number(raw.score),
      passed: raw.passed,
      correct: raw.correct,
      total: raw.total,
      passingScore: Number(raw.passing_score),
      results: raw.results.map((r) => ({
        questionId: r.question_id,
        correct: r.correct,
        correctOptionIds: r.correct_option_ids,
      })),
      newMedal: raw.new_medal,
    };
  }

  // --- Apoyo ----------------------------------------------------------------

  private async completedLessonIds(): Promise<Set<string>> {
    const { data } = await this.supabase
      .from('lesson_progress')
      .select('lesson_id')
      .eq('status', 'completed');
    return new Set((data ?? []).map((row) => row.lesson_id));
  }

  private requireUser(): string {
    const userId = this.auth.session()?.user.id;
    if (!userId) throw new Error('Necesitas iniciar sesión.');
    return userId;
  }
}
