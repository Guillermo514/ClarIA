import { Routes } from '@angular/router';

import { authGuard, guestGuard } from './core/auth/auth.guards';

export const routes: Routes = [
  // --- Páginas públicas -----------------------------------------------------
  {
    path: 'ingresar',
    canActivate: [guestGuard],
    loadComponent: () => import('./features/auth/login.page').then((m) => m.LoginPage),
    title: 'Iniciar sesión · ClarIA',
  },
  {
    path: 'registro',
    canActivate: [guestGuard],
    loadComponent: () => import('./features/auth/register.page').then((m) => m.RegisterPage),
    title: 'Crear cuenta · ClarIA',
  },
  {
    path: 'aviso-de-privacidad',
    loadComponent: () => import('./features/privacy/privacy.page').then((m) => m.PrivacyPage),
    title: 'Aviso de privacidad · ClarIA',
  },

  // --- Páginas con sesión iniciada ------------------------------------------
  {
    path: '',
    canActivateChild: [authGuard],
    children: [
      {
        path: 'inicio',
        loadComponent: () => import('./features/home/home.page').then((m) => m.HomePage),
        title: 'Inicio · ClarIA',
      },
      {
        path: 'cursos',
        loadComponent: () => import('./features/courses/courses.page').then((m) => m.CoursesPage),
        title: 'Cursos · ClarIA',
      },
      {
        path: 'cursos/:nivel',
        loadComponent: () => import('./features/level/level.page').then((m) => m.LevelPage),
        title: 'Nivel · ClarIA',
      },
      {
        path: 'cursos/:nivel/leccion/:codigo',
        loadComponent: () => import('./features/lesson/lesson.page').then((m) => m.LessonPage),
        title: 'Lección · ClarIA',
      },
      {
        path: 'evaluaciones',
        loadComponent: () =>
          import('./features/evaluations/evaluations.page').then((m) => m.EvaluationsPage),
        title: 'Evaluaciones · ClarIA',
      },
      {
        path: 'evaluaciones/:nivel',
        loadComponent: () => import('./features/quiz/quiz.page').then((m) => m.QuizPage),
        title: 'Evaluación · ClarIA',
      },
      {
        path: 'logros',
        loadComponent: () =>
          import('./features/achievements/achievements.page').then((m) => m.AchievementsPage),
        title: 'Logros · ClarIA',
      },
      {
        path: 'flashcards',
        loadComponent: () =>
          import('./features/flashcards/flashcards.page').then((m) => m.FlashcardsPage),
        title: 'Flashcards · ClarIA',
      },
      {
        path: 'articulos',
        loadComponent: () =>
          import('./features/articles/articles.page').then((m) => m.ArticlesPage),
        title: 'Artículos · ClarIA',
      },
      {
        path: 'tokenizador',
        loadComponent: () =>
          import('./features/tokenizer/tokenizer.page').then((m) => m.TokenizerPage),
        title: 'Tokenizador · ClarIA',
      },
      {
        path: 'evaluador',
        loadComponent: () =>
          import('./features/prompt-evaluator/prompt-evaluator.page').then(
            (m) => m.PromptEvaluatorPage,
          ),
        title: 'Evaluador de IA · ClarIA',
      },
      // El detector de alucinaciones fue reemplazado por el evaluador.
      { path: 'detector', redirectTo: 'evaluador' },
      { path: '', pathMatch: 'full', redirectTo: 'inicio' },
    ],
  },
  { path: '**', redirectTo: 'inicio' },
];
