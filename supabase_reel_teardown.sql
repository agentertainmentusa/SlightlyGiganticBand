-- ============================================================
-- Slightly Gigantic — Fan Reel Challenge full teardown
-- Run this in Supabase SQL Editor (project: slightlygigantic ttsvbrotqisylbtrzimy)
-- Paste, click Run. Safe to run multiple times.
-- ============================================================

-- ---- Step 1: See the current save_site_content definition ----
-- Run this by itself first so we know exactly what to patch below.
-- (Just uncomment, run, and copy the output back to me if you want me to patch it precisely.)
--
-- SELECT pg_get_functiondef(oid)
-- FROM pg_proc
-- WHERE proname = 'save_site_content';


-- ---- Step 2: Drop the 5 reel RPCs (safe to run whether or not they exist) ----
DO $$
DECLARE fn text;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure::text FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('submit_reel','list_approved_reels','admin_list_reels','admin_review_reel','admin_delete_reel')
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', fn);
  END LOOP;
END$$;


-- ---- Step 3: Drop the reel_submissions table ----
DROP TABLE IF EXISTS public.reel_submissions CASCADE;


-- ---- Step 4: Patch save_site_content to remove reelChallenge from required keys ----
-- Because your admin.html no longer sends reelChallenge in the payload, the current
-- function (which requires it) will start rejecting saves.
--
-- The safest fix without seeing the current source: this small helper snippet drops the
-- reelChallenge requirement from the function body IF the function uses a simple
-- "required key" list. It uses regex on the function source, then applies the patch.
DO $$
DECLARE
  src text;
  new_src text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
  FROM pg_proc WHERE proname = 'save_site_content' LIMIT 1;

  IF src IS NULL THEN
    RAISE NOTICE 'save_site_content not found — no patch needed.';
    RETURN;
  END IF;

  -- Remove any "reelChallenge" string from the required-keys array. Handles:
  --   'reelChallenge',
  --   ,'reelChallenge'
  --   ,'reelChallenge',
  new_src := regexp_replace(src, E',?\\s*''reelChallenge''\\s*,?', '', 'g');
  -- Clean any doubled commas that regex may have left
  new_src := regexp_replace(new_src, E',\\s*,', ',', 'g');
  -- Clean any leading comma inside array literals
  new_src := regexp_replace(new_src, E'ARRAY\\[\\s*,', 'ARRAY[', 'g');

  IF new_src = src THEN
    RAISE NOTICE 'No reelChallenge reference found in save_site_content — no patch needed.';
    RETURN;
  END IF;

  EXECUTE new_src;
  RAISE NOTICE 'save_site_content patched: reelChallenge removed from required keys.';
END$$;


-- ---- Step 5 (optional): Also strip the reelChallenge key from the stored site content JSON ----
UPDATE public.site_content
SET data = data - 'reelChallenge'
WHERE id = 1 AND (data ? 'reelChallenge');


-- Done. Verify:
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname IN ('submit_reel','list_approved_reels','admin_list_reels','admin_review_reel','admin_delete_reel')) AS reel_rpcs_remaining,
  to_regclass('public.reel_submissions') AS reel_table_remaining,
  (SELECT data ? 'reelChallenge' FROM public.site_content WHERE id = 1) AS reel_key_in_content;
-- All three should be: 0, NULL, false
