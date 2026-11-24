import os
import sqlite3
import sys
from contextlib import closing

from cps import constants, ub
from cps.cwa_db_loader import load_cwa_db
from werkzeug.security import generate_password_hash

from acsm import configure_acsm, prepare_upload_validator


sys.path.insert(0, "/app/calibre-web-automated/scripts")
from auto_library import create_appdb


app_db = "/config/app.db"
operator = "calibre-local-admin"
password_hash = generate_password_hash(os.environ["CALIBRE_NEXTGEN_ADMIN_PASSWORD"])
# s6 requires /run to belong to its runtime UID. Kubernetes owns the volume root.
os.makedirs("/runtime/s6", mode=0o755, exist_ok=True)
configure_acsm()
prepare_upload_validator()
create_appdb(app_db)
ub.dispose()

with closing(sqlite3.connect(app_db)) as database, database:
    updated = database.execute(
        """UPDATE user SET name = ?, email = ?, password = ?, share_shelfs = 0
           WHERE name IN ('admin', ?) AND (role & ?) != 0""",
        (operator, f"{operator}@example.invalid", password_hash, operator, constants.ROLE_ADMIN),
    )
    if updated.rowcount != 1:
        raise RuntimeError("Expected exactly one local maintenance account")

    database.execute("""UPDATE settings SET
        config_uploading = 1, config_upload_formats = 'epub,acsm',
        config_upload_formats_lcpl_migrated = 1, config_upload_formats_fbz_migrated = 1,
        config_anonbrowse = 0, config_public_reg = 0, config_embed_metadata = 0,
        config_enable_oauth_group_admin_management = 1, config_enable_oauth_auto_forward = 1,
        config_disable_standard_login = 1,
        config_oauth_redirect_host = 'https://books.laboratory.casa'
    """)

    # Backfill the shelf-sharing default for existing household OIDC readers.
    database.execute("""UPDATE user SET share_shelfs = 1
        WHERE (role & ?) = 0 AND share_shelfs = 0
          AND EXISTS (
            SELECT 1 FROM flask_dance_oauth AS oauth
            JOIN oauthProvider AS provider ON oauth.provider = CAST(provider.id AS TEXT)
            WHERE oauth.user_id = user.id AND provider.provider_name = 'generic'
          )
    """, (constants.ROLE_ADMIN | constants.ROLE_ANONYMOUS,))

    # v4.1.74 provisions OIDC users in the shared library. Give readers an empty
    # My Library at INSERT time, before the first login can see any books.
    # The seed fence prevents the app from copying the global catalog later.
    # The OIDC provisioner assigns only ROLE_ADMIN to first-time administrators.
    # Keep their reader permissions even if OIDC later removes the admin role.
    reader_roles = constants.ROLE_DOWNLOAD | constants.ROLE_UPLOAD | constants.ROLE_VIEWER
    database.execute("DROP TRIGGER IF EXISTS calibre_nextgen_private_reader")
    database.execute(f"""CREATE TRIGGER calibre_nextgen_private_reader AFTER INSERT ON user
        WHEN (NEW.role & {constants.ROLE_ANONYMOUS}) = 0
        BEGIN
            UPDATE user SET has_own_library = 1, user_library_seeded = 1,
                share_shelfs = (NEW.role & {constants.ROLE_ADMIN}) = 0,
                kobo_only_shelves_sync = 0,
                role = role | CASE WHEN NEW.role = {constants.ROLE_ADMIN} THEN {reader_roles} ELSE 0 END
            WHERE id = NEW.id;
        END
    """)

settings = load_cwa_db().CWA_DB()
settings.execute_write("""UPDATE cwa_settings SET
    default_settings = 0, koreader_sync_enabled = 1, archived_cleanup_enabled = 0,
    auto_backup_imports = 0, auto_backup_conversions = 0, auto_backup_epub_fixes = 0,
    auto_zip_backups = 0, duplicate_scan_frequency = 'manual', auto_convert = 0,
    auto_metadata_enforcement = 0, kindle_epub_fixer = 0,
    auto_metadata_fetch_enabled = 1, auto_metadata_smart_application = 1,
    auto_metadata_update_series = 1, auto_metadata_update_title = 0,
    auto_metadata_update_authors = 0, auto_metadata_update_description = 0,
    auto_metadata_update_publisher = 0, auto_metadata_update_tags = 0,
    auto_metadata_update_rating = 0, auto_metadata_update_published_date = 0,
    auto_metadata_update_identifiers = 0, auto_metadata_update_cover = 0
""")
# Include Wikidata for series lookup while preserving the configured provider priority.
settings.execute_write("""UPDATE cwa_settings
    SET metadata_provider_hierarchy = json_insert(metadata_provider_hierarchy, '$[#]', 'wikidata')
    WHERE json_valid(metadata_provider_hierarchy)
      AND NOT EXISTS (SELECT 1 FROM json_each(metadata_provider_hierarchy) WHERE value = 'wikidata')
""")
settings.con.close()
