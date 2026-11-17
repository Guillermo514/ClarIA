-- =============================================================================
-- ClarIA 2.0 · Migración 7: «¡La domino!» con upsert
-- El upsert de supabase-js actualiza todas las columnas que envía (user_id,
-- card_id, box, next_review_at). La política RLS ya impide tocar tarjetas de
-- otro usuario; seen_at sigue reservado a mark_flashcard_seen().
-- =============================================================================

grant update (user_id, card_id, box, next_review_at) on public.flashcard_reviews to authenticated;
