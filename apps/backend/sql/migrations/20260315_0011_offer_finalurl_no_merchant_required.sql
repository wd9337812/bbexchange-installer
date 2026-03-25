ALTER TABLE IF EXISTS offers
  ADD COLUMN IF NOT EXISTS final_url text NOT NULL DEFAULT '';

ALTER TABLE IF EXISTS offers
  ADD COLUMN IF NOT EXISTS exclude_address_path text NOT NULL DEFAULT '';

ALTER TABLE IF EXISTS offers
  ALTER COLUMN merchant_id DROP NOT NULL;

-- Backfill final_url from existing offer_url where possible.
UPDATE offers
SET final_url = offer_url
WHERE coalesce(final_url, '') = '' AND coalesce(offer_url, '') <> '';

CREATE INDEX IF NOT EXISTS idx_offers_final_url ON offers(final_url);
