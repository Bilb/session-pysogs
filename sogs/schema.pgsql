
BEGIN;

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;

CREATE TABLE rooms (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, /* internal database id of the room */
    token CITEXT NOT NULL UNIQUE, /* case-insensitive room identifier used in URLs, etc. */
    name TEXT NOT NULL, /* Publicly visible room name */
    description TEXT, /* Publicly visible room description */
    image BIGINT, /* foreign key to files(id) */
    created FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    message_sequence BIGINT NOT NULL DEFAULT 0, /* monotonic current top message.seqno value: +1 for each new message, edit or deletion */
    info_updates BIGINT NOT NULL DEFAULT 0, /* +1 for any room metadata update (name/desc/image/pinned/mods) */
    active_users BIGINT NOT NULL DEFAULT 0,
    read BOOLEAN NOT NULL DEFAULT TRUE, /* Whether users can read by default */
    accessible BOOLEAN NOT NULL DEFAULT TRUE, /* Whether room metadata is accessible when `read` is false */
    write BOOLEAN NOT NULL DEFAULT TRUE, /* Whether users can post by default */
    upload BOOLEAN NOT NULL DEFAULT TRUE, /* Whether file uploads are allowed by default */
    CHECK(token SIMILAR TO '[a-zA-Z0-9_-]+')
);

-- Trigger to expire an old room image attachment when the room image is changed
CREATE OR REPLACE FUNCTION trigger_room_image_expiry()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE files SET expiry = 0.0 WHERE id = OLD.image;
    RETURN NULL;
END;$$;
CREATE TRIGGER room_image_expiry AFTER UPDATE OF image ON rooms
FOR EACH ROW WHEN (NEW.image IS DISTINCT FROM OLD.image AND OLD.image IS NOT NULL)
EXECUTE PROCEDURE trigger_room_image_expiry();

CREATE TABLE messages (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    room BIGINT NOT NULL REFERENCES rooms ON DELETE CASCADE,
    "user" BIGINT NOT NULL, /* foreign key to users(id) */
    posted FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    edited FLOAT,
    seqno BIGINT NOT NULL DEFAULT 0, /* set to the room's `message_sequence` counter when any of the individual seqno values are updated */
    seqno_data BIGINT NOT NULL DEFAULT 0, /* updated when `data` changes (i.e. edits, deletions) */
    seqno_reactions BIGINT NOT NULL DEFAULT 0, /* updated when reactions are added/removed */
    data BYTEA, /* Actual message content, not including trailing padding; set to null to delete a message */
    data_size BIGINT, /* The message size, including trailing padding (needed because the signature is over the padded data) */
    signature BYTEA, /* Signature of `data` by `public_key`; set to null when deleting a message */
    filtered BOOLEAN NOT NULL DEFAULT FALSE, /* If true then we accept the message but never distribute it (e.g. for silent filtration) */
    whisper BIGINT, /* foreign key to users(id): If set this is a whisper meant for the given user */
    whisper_mods BOOLEAN NOT NULL DEFAULT FALSE /* If true: this is a whisper that all mods should see (may or may not have a `whisper` target) */
);
CREATE INDEX messages_room ON messages(room, posted);
CREATE INDEX messages_updated ON messages(room, seqno);
CREATE INDEX messages_id ON messages(room, id);

CREATE TABLE message_history (
    message BIGINT NOT NULL REFERENCES messages ON DELETE CASCADE,
    replaced FLOAT NOT NULL DEFAULT (extract(epoch from now())), /* unix epoch when this historic value was replaced by an edit or deletion */
    data TEXT NOT NULL, /* the content prior to the update/delete */
    signature BYTEA NOT NULL /* signature prior to the update/delete */
);
CREATE INDEX message_history_message ON message_history(message);
CREATE INDEX message_history_replaced ON message_history(replaced);

CREATE OR REPLACE FUNCTION increment_room_sequence(room_id BIGINT)
RETURNS BIGINT LANGUAGE PLPGSQL AS $$
DECLARE
    new_seqno BIGINT;
BEGIN
    UPDATE rooms SET message_sequence = message_sequence + 1 WHERE id = room_id
        RETURNING message_sequence INTO STRICT new_seqno;
    RETURN new_seqno;
END;$$;

-- Trigger to increment a room's `message_sequence` counter and assign it to the message's `seqno`
-- field for new messages.
CREATE OR REPLACE FUNCTION trigger_messages_insert_counter()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE messages SET seqno_data = increment_room_sequence(NEW.room) WHERE id = NEW.id;
    RETURN NULL;
END;$$;
CREATE TRIGGER messages_insert_counter AFTER INSERT ON messages
FOR EACH ROW EXECUTE PROCEDURE trigger_messages_insert_counter();

-- Trigger to do various tasks needed when a message is edited/deleted:
-- * record the old value into message_history
-- * update the room's `message_sequence` counter (so that clients can learn about the update)
-- * update the message's `seqno_data` value to that new counter
-- * update the message's `edit` timestamp
CREATE OR REPLACE FUNCTION trigger_messages_insert_history()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    INSERT INTO message_history (message, data, signature) VALUES (NEW.id, OLD.data, OLD.signature);
    UPDATE messages SET
        seqno_data = increment_room_sequence(NEW.room),
        edited = (extract(epoch from now()))
    WHERE id = NEW.id;
    RETURN NULL;
END;$$;
CREATE TRIGGER messages_insert_history AFTER UPDATE OF data ON messages
FOR EACH ROW WHEN (NEW.data IS DISTINCT FROM OLD.data)
EXECUTE PROCEDURE trigger_messages_insert_history();

-- Trigger to update seqno when any of the seqno_* indicators is updated, so that updating can
-- update just the seqno_whatever and have the master seqno get updated automatically.
CREATE OR REPLACE FUNCTION trigger_messages_seqno()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE messages SET seqno = GREATEST(seqno_data, seqno_reactions)
        WHERE id = NEW.id;
    RETURN NULL;
END;$$;
CREATE TRIGGER messages_seqno_updater
AFTER INSERT OR UPDATE OF seqno_data, seqno_reactions ON messages
FOR EACH ROW EXECUTE PROCEDURE trigger_messages_seqno();



CREATE TABLE pinned_messages (
    room BIGINT NOT NULL REFERENCES rooms ON DELETE CASCADE,
    message BIGINT NOT NULL REFERENCES messages ON DELETE CASCADE,
    pinned_by BIGINT NOT NULL, /* foreign key to users(id) */
    pinned_at FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    PRIMARY KEY(room, message)
);


CREATE TABLE files (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    room BIGINT REFERENCES rooms ON DELETE SET NULL,
    uploader BIGINT,
    message BIGINT REFERENCES messages ON DELETE SET NULL,
    size BIGINT NOT NULL,
    uploaded FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    expiry FLOAT DEFAULT (extract(epoch from now() + '15 days')),
    filename TEXT, /* user-provided filename */
    path TEXT NOT NULL /* path on disk */
);
CREATE INDEX files_room ON files(room);
CREATE INDEX files_expiry ON files(expiry);
CREATE INDEX files_message ON files(message);
-- When we delete a room all its files will have room set to NULL but we *also* need to mark them
-- for immediate expiry so that the file pruner finds them to clean them up at the next cleanup
-- check.
CREATE OR REPLACE FUNCTION trigger_room_expire_roomless()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE files SET expiry = 0.0 WHERE id = NEW.id;
    RETURN NULL;
END;$$;
CREATE TRIGGER room_expire_roomless AFTER UPDATE OF room ON files
FOR EACH ROW WHEN (NEW.room IS NULL)
EXECUTE PROCEDURE trigger_room_expire_roomless();

ALTER TABLE rooms ADD CONSTRAINT room_image_fk FOREIGN KEY (image) REFERENCES files ON DELETE SET NULL;


-- Trigger to handle required updates after a message gets deleted (in the SOGS context: that is,
-- has data set to NULL)
CREATE OR REPLACE FUNCTION trigger_messages_after_delete()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    -- Unpin if we deleted a pinned message:
    DELETE FROM pinned_messages WHERE message = OLD.id;
    -- Expire the posts attachments immediately:
    UPDATE files SET expiry = 0.0 WHERE message = OLD.id;
    RETURN NULL;
END;$$;
CREATE TRIGGER messages_after_delete AFTER UPDATE OF data ON messages
FOR EACH ROW WHEN (NEW.data IS NULL AND OLD.data IS NOT NULL)
EXECUTE PROCEDURE trigger_messages_after_delete();


CREATE TABLE users (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    session_id TEXT NOT NULL UNIQUE,
    created FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    last_active FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    banned BOOLEAN NOT NULL DEFAULT FALSE, /* true = globally banned from all rooms */
    moderator BOOLEAN NOT NULL DEFAULT FALSE, /* true = moderator of all rooms, and can add global bans */
    admin BOOLEAN NOT NULL DEFAULT FALSE, /* true = admin of all rooms, and can appoint global bans/mod/admins */
    visible_mod BOOLEAN NOT NULL DEFAULT FALSE, /* if true this user's moderator status is viewable by regular room users of all rooms */
    CHECK(NOT (banned AND (moderator OR admin))) /* someone cannot be banned *and* a moderator at the same time */
);
CREATE INDEX users_last_active ON users(last_active);

ALTER TABLE messages ADD CONSTRAINT messages_user_fk FOREIGN KEY ("user") REFERENCES users;
ALTER TABLE messages ADD CONSTRAINT messages_whisper_fk FOREIGN KEY (whisper) REFERENCES users;
ALTER TABLE files ADD CONSTRAINT files_uploader_fk FOREIGN KEY (uploader) REFERENCES users;
ALTER TABLE pinned_messages ADD CONSTRAINT pinned_messages_pinned_by FOREIGN KEY (pinned_by) REFERENCES users;

-- Create a trigger to maintain the implication "admin implies moderator"
CREATE OR REPLACE FUNCTION trigger_user_admins_are_mods()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE users SET moderator = TRUE WHERE id = NEW.id;
    RETURN NULL;
END;$$;
CREATE TRIGGER user_admins_are_mods
    AFTER INSERT OR UPDATE OF moderator, admin
    ON users
FOR EACH ROW WHEN (NEW.admin AND NOT NEW.moderator)
EXECUTE PROCEDURE trigger_user_admins_are_mods();


-- This table tracks unblinded session ids in user_permission (and related) rows that need to be
-- blinded, which will happen the first time the user authenticates with their blinded id (until
-- they do, we can't know the actual sign bit of their blinded id).  It is populated at startup
-- when blinding is first enabled, and is used both for the initial blinding transition and when
-- ids are added by raw session ID (e.g. when adding a moderator by session id).
CREATE TABLE needs_blinding (
    blinded_abs TEXT NOT NULL PRIMARY KEY, -- the positive of the possible two blinded keys
    "user" BIGINT NOT NULL UNIQUE REFERENCES users ON DELETE CASCADE
);


-- Reactions
CREATE TABLE reactions (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    message BIGINT NOT NULL REFERENCES messages ON DELETE CASCADE,
    reaction TEXT NOT NULL
);
CREATE UNIQUE INDEX reactions_message ON reactions (message, reaction);

CREATE TABLE user_reactions (
    reaction BIGINT NOT NULL REFERENCES reactions ON DELETE CASCADE,
    "user" BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    at FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    PRIMARY KEY(reaction, "user")
);
CREATE INDEX user_reactions_at ON user_reactions(reaction, at);

CREATE VIEW message_reactions AS
SELECT reactions.*, user_reactions.user, user_reactions.at
FROM reactions JOIN user_reactions ON user_reactions.reaction = reactions.id;


CREATE OR REPLACE FUNCTION trigger_message_reactions_insert()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    INSERT INTO reactions (message, reaction) VALUES (NEW.message, NEW.reaction)
        ON CONFLICT (message, reaction) DO NOTHING;
    INSERT INTO user_reactions (reaction, "user") VALUES (
        (SELECT id FROM reactions WHERE message = NEW.message AND reaction = NEW.reaction),
        NEW."user");
    RETURN NULL;
END;$$;
CREATE TRIGGER message_reactions_insert INSTEAD OF INSERT ON message_reactions
FOR EACH ROW
EXECUTE PROCEDURE trigger_message_reactions_insert();



-- View used to select the first n reactors (using `WHERE _order <= 5`).
CREATE VIEW first_reactors AS
SELECT *, rank() OVER (PARTITION BY reaction ORDER BY at) AS _order
FROM user_reactions;


CREATE OR REPLACE FUNCTION trigger_reactions_no_update()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    RAISE 'reactions/user_reactions tables are not UPDATEable';
END;$$;
CREATE TRIGGER reactions_no_update BEFORE UPDATE ON reactions
FOR EACH STATEMENT
EXECUTE PROCEDURE trigger_reactions_no_update();
CREATE TRIGGER user_reactions_no_update BEFORE UPDATE ON user_reactions
FOR EACH STATEMENT
EXECUTE PROCEDURE trigger_reactions_no_update();


CREATE OR REPLACE FUNCTION trigger_user_reactions_seqno_insert()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
DECLARE
    msg_id BIGINT;
    room_id BIGINT;
BEGIN
    SELECT message INTO STRICT msg_id FROM reactions WHERE id = NEW.reaction;
    SELECT room INTO STRICT room_id FROM messages WHERE id = msg_id;
    UPDATE messages SET seqno_reactions = increment_room_sequence(room_id)
        WHERE id = msg_id;
    RETURN NULL;
END;$$;
CREATE TRIGGER user_reactions_insert_seqno AFTER INSERT ON user_reactions
FOR EACH ROW EXECUTE PROCEDURE trigger_user_reactions_seqno_insert();

CREATE OR REPLACE FUNCTION trigger_user_reactions_seqno_delete()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
DECLARE
    msg_id BIGINT;
    room_id BIGINT;
BEGIN
    SELECT message INTO STRICT msg_id FROM reactions WHERE id = OLD.reaction;
    SELECT room INTO STRICT room_id FROM messages WHERE id = msg_id;
    UPDATE messages SET seqno_reactions = increment_room_sequence(room_id)
        WHERE id = msg_id;
    RETURN OLD;
END;$$;
CREATE TRIGGER user_reactions_delete_seqno BEFORE DELETE ON user_reactions
FOR EACH ROW EXECUTE PROCEDURE trigger_user_reactions_seqno_delete();

-- Trigger to delete the reactions row when we delete the last referencing user reaction
CREATE OR REPLACE FUNCTION trigger_reactions_clear_empty()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    DELETE FROM reactions WHERE id = OLD.reaction
        AND NOT EXISTS(SELECT * FROM user_reactions WHERE reaction = reactions.id);
    RETURN NULL;
END;$$;
CREATE TRIGGER reactions_clear_empty AFTER DELETE ON user_reactions
FOR EACH ROW
EXECUTE PROCEDURE trigger_reactions_clear_empty();


-- Effectively the same as `messages` except that it also includes the `session_id` from the users
-- table of the user who posted it, and the session id of the whisper recipient (as `whisper_to`) if
-- a directed whisper.
CREATE VIEW message_details AS
SELECT messages.*, uposter.session_id, uwhisper.session_id AS whisper_to
    FROM messages
        JOIN users uposter ON messages.user = uposter.id
        LEFT JOIN users uwhisper ON messages.whisper = uwhisper.id;

-- Delete trigger on message_details which lets us use a DELETE that gets transformed into an UPDATE
-- that sets data, size, signature to NULL on the matched messages.
CREATE OR REPLACE FUNCTION trigger_message_details_deleter()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    IF OLD.data IS NOT NULL THEN
        UPDATE messages SET data = NULL, data_size = NULL, signature = NULL
            WHERE id = OLD.id;
        DELETE FROM user_reactions WHERE reaction IN (
            SELECT id FROM reactions WHERE message = OLD.id);
    END IF;
    RETURN NULL;
END;$$;
CREATE TRIGGER message_details_deleter INSTEAD OF DELETE ON message_details
FOR EACH ROW
EXECUTE PROCEDURE trigger_message_details_deleter();

-- View of `messages` that is useful for manually inspecting table contents by only returning the
-- length (rather than raw bytes) for data/signature.
CREATE VIEW message_metadata AS
SELECT id, room, "user", session_id, posted, edited, seqno, seqno_data, seqno_reactions,
        filtered, whisper_to, whisper_mods,
        length(data) AS data_unpadded, data_size, length(signature) as signature_length
    FROM message_details;



CREATE TABLE room_users (
    room BIGINT NOT NULL REFERENCES rooms ON DELETE CASCADE,
    "user" BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    last_active FLOAT NOT NULL DEFAULT (extract(epoch from now())),
    PRIMARY KEY(room, "user")
);
CREATE INDEX room_users_room_activity ON room_users(room, last_active);
CREATE INDEX room_users_activity ON room_users(last_active);

-- Stores permissions or restrictions on a user.  Null values (for read/write) mean "user the room's
-- default".
CREATE TABLE user_permission_overrides (
    room BIGINT NOT NULL REFERENCES rooms ON DELETE CASCADE,
    "user" BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    banned BOOLEAN NOT NULL DEFAULT FALSE, /* If true the user is banned */
    read BOOLEAN, /* If false the user may not fetch messages; null uses room default; true allows reading */
    accessible BOOLEAN, /* When read is false this controls whether room metadata is still visible */
    write BOOLEAN, /* If false the user may not post; null uses room default; true allows posting */
    upload BOOLEAN, /* If false the user may not upload files; null uses room default; true allows uploading */
    moderator BOOLEAN NOT NULL DEFAULT FALSE, /* If true the user may moderate non-moderators */
    admin BOOLEAN NOT NULL DEFAULT FALSE, /* If true the user may moderate anyone (including other moderators and admins) */
    visible_mod BOOLEAN NOT NULL DEFAULT TRUE, /* If true then this user (if a moderator) is included in the list of a room's public moderators */
    PRIMARY KEY(room, "user"),
    CHECK(NOT (banned AND (moderator OR admin))) /* Mods/admins cannot be banned */
);
CREATE INDEX user_permission_overrides_mods ON user_permission_overrides(room) WHERE moderator;

-- Create a trigger to maintain the implication "admin implies moderator"
CREATE OR REPLACE FUNCTION trigger_user_perms_admins_are_mods()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE user_permission_overrides SET moderator = TRUE WHERE room = NEW.room AND "user" = NEW."user";
    RETURN NULL;
END;$$;
CREATE TRIGGER user_perms_admins_are_mods
    AFTER INSERT OR UPDATE OF moderator, admin
    ON user_permission_overrides
FOR EACH ROW WHEN (NEW.admin AND NOT NEW.moderator)
EXECUTE PROCEDURE trigger_user_perms_admins_are_mods();

-- Trigger that removes useless empty permission override rows (e.g. after a ban gets removed, and
-- no other permissions roles are set).
CREATE OR REPLACE FUNCTION trigger_user_perms_empty_cleanup()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    DELETE from user_permission_overrides WHERE room = NEW.room AND "user" = NEW."user";
    RETURN NULL;
END;$$;
CREATE TRIGGER user_perms_empty_cleanup AFTER UPDATE ON user_permission_overrides
FOR EACH ROW WHEN (NOT (NEW.banned OR NEW.moderator OR NEW.admin)
    AND COALESCE(NEW.accessible, NEW.read, NEW.write, NEW.upload) IS NULL)
EXECUTE PROCEDURE trigger_user_perms_empty_cleanup();

-- Triggers than remove a user from `room_users` when they are banned from the room
CREATE OR REPLACE FUNCTION trigger_room_users_remove_banned()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    DELETE FROM room_users WHERE room = NEW.room AND "user" = NEW."user";
    RETURN NULL;
END;$$;
CREATE TRIGGER room_users_remove_banned AFTER UPDATE OF banned ON user_permission_overrides
FOR EACH ROW WHEN (NEW.banned)
EXECUTE PROCEDURE trigger_room_users_remove_banned();


-- Triggers to update `rooms.info_updates` on metadata column changes
CREATE OR REPLACE FUNCTION trigger_room_metadata_update()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE rooms SET info_updates = info_updates + 1 WHERE id = NEW.id;
    RETURN NULL;
END;$$;
CREATE TRIGGER room_metadata_update AFTER UPDATE ON rooms
FOR EACH ROW WHEN (
    NEW.name IS DISTINCT FROM OLD.name OR
    NEW.description IS DISTINCT FROM OLD.description OR
    NEW.image IS DISTINCT FROM OLD.image)
EXECUTE PROCEDURE trigger_room_metadata_update();

-- Triggers to update `info_updates` when the mod list or pinned message changes:
CREATE OR REPLACE FUNCTION trigger_room_metadata_info_update_new()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE rooms SET info_updates = info_updates + 1 WHERE id = NEW.room;
    RETURN NULL;
END;$$;
CREATE OR REPLACE FUNCTION trigger_room_metadata_info_update_old()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE rooms SET info_updates = info_updates + 1 WHERE id = OLD.room;
    RETURN NULL;
END;$$;
CREATE OR REPLACE FUNCTION trigger_room_metadata_info_update_all()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE rooms SET info_updates = info_updates + 1;
    RETURN NULL;
END;$$;
CREATE TRIGGER room_metadata_mods_insert AFTER INSERT ON user_permission_overrides
FOR EACH ROW WHEN (NEW.moderator OR NEW.admin)
EXECUTE PROCEDURE trigger_room_metadata_info_update_new();

CREATE TRIGGER room_metadata_mods_update AFTER UPDATE OF moderator, admin ON user_permission_overrides
FOR EACH ROW WHEN (NEW.moderator != OLD.moderator OR NEW.admin != OLD.admin)
EXECUTE PROCEDURE trigger_room_metadata_info_update_new();

CREATE TRIGGER room_metadata_mods_delete AFTER DELETE ON user_permission_overrides
FOR EACH ROW WHEN (OLD.moderator OR OLD.admin)
EXECUTE PROCEDURE trigger_room_metadata_info_update_old();

-- Trigger to update `info_updates` of all rooms whenever we add/remove a global moderator/admin
-- because global mod settings affect the permissions of all rooms (and polling clients need to pick
-- up on this).
CREATE TRIGGER room_metadata_global_mods_insert AFTER INSERT ON users
FOR EACH ROW WHEN (NEW.admin OR NEW.moderator)
EXECUTE PROCEDURE trigger_room_metadata_info_update_all();

CREATE TRIGGER room_metadata_global_mods_update AFTER UPDATE OF moderator, admin, visible_mod ON users
FOR EACH ROW WHEN (NEW.moderator != OLD.moderator OR NEW.admin != OLD.admin OR NEW.visible_mod != OLD.visible_mod)
EXECUTE PROCEDURE trigger_room_metadata_info_update_all();

CREATE TRIGGER room_metadata_global_mods_delete AFTER DELETE ON users
FOR EACH ROW WHEN (OLD.moderator OR OLD.admin)
EXECUTE PROCEDURE trigger_room_metadata_info_update_all();


-- Triggers for change to pinned messages
CREATE OR REPLACE FUNCTION trigger_room_metadata_pinned_add()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE rooms SET info_updates = info_updates + 1 WHERE id = NEW.room;
    UPDATE files SET expiry = NULL WHERE message = NEW.message;
    RETURN NULL;
END;$$;
CREATE TRIGGER room_metadata_pinned_add AFTER INSERT OR UPDATE ON pinned_messages
FOR EACH ROW
EXECUTE PROCEDURE trigger_room_metadata_pinned_add();

CREATE OR REPLACE FUNCTION trigger_room_metadata_pinned_remove()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$BEGIN
    UPDATE rooms SET info_updates = info_updates + 1 WHERE id = OLD.room;
    UPDATE files SET expiry = uploaded + 15.0*86400.0 WHERE message = OLD.message;
    RETURN NULL;
END;$$;
CREATE TRIGGER room_metadata_pinned_remove AFTER DELETE ON pinned_messages
FOR EACH ROW
EXECUTE PROCEDURE trigger_room_metadata_pinned_remove();



-- View of permissions; for users with an entry in user_permissions we use those values; for null
-- values or no user_permissions entry we return the room's default read/write values (and false for
-- the other fields).  This view should only be used for querying individual user permissions as it
-- will involve a full table scan on `users` if not given a "user" value in the query.
CREATE VIEW user_permissions AS
SELECT
    rooms.id AS room,
    users.id AS "user",
    users.session_id,
    CASE WHEN users.banned THEN TRUE ELSE COALESCE(user_permission_overrides.banned, FALSE) END AS banned,
    CASE WHEN users.moderator THEN TRUE ELSE COALESCE(user_permission_overrides.read, rooms.read) END AS read,
    CASE WHEN users.moderator THEN TRUE ELSE COALESCE(user_permission_overrides.accessible, rooms.accessible) END AS accessible,
    CASE WHEN users.moderator THEN TRUE ELSE COALESCE(user_permission_overrides.write, rooms.write) END AS write,
    CASE WHEN users.moderator THEN TRUE ELSE COALESCE(user_permission_overrides.upload, rooms.upload) END AS upload,
    CASE WHEN users.moderator THEN TRUE ELSE COALESCE(user_permission_overrides.moderator, FALSE) END AS moderator,
    CASE WHEN users.admin THEN TRUE ELSE COALESCE(user_permission_overrides.admin, FALSE) END AS admin,
    -- room_moderator will be TRUE if the user is specifically listed as a moderator of the room
    COALESCE(user_permission_overrides.moderator, FALSE) AS room_moderator,
    -- global_moderator will be TRUE if the user is a global moderator/admin (note that this is
    -- *not* exclusive of room_moderator: a moderator/admin could be listed in both).
    users.moderator as global_moderator,
    -- visible_mod will be TRUE if this mod is a publicly viewable moderator of the room
    CASE
        WHEN user_permission_overrides.moderator THEN user_permission_overrides.visible_mod
        WHEN users.moderator THEN users.visible_mod
        ELSE FALSE
    END AS visible_mod
FROM
    users CROSS JOIN rooms LEFT OUTER JOIN user_permission_overrides ON
        (users.id = user_permission_overrides."user" AND rooms.id = user_permission_overrides.room);

-- Used to accesses the moderator list for a room.  This view is considerably faster than querying
-- the `user_permissions` table for a list of all moderators.
CREATE VIEW room_moderators AS
SELECT session_id, mods.* FROM (
    SELECT
        room,
        "user",
        -- visible_mod gets priority from the per-room row if it exists, so we use 3/2 for the
        -- per-room value below, 1/0 for the global value, take the max, then look for an odd value
        -- to give us the visibility bit:
        CAST(MAX(visible_mod) & 1 AS BOOLEAN) AS visible_mod,
        bool_or(admin) AS admin,
        bool_or(room_moderator) AS room_moderator,
        bool_or(global_moderator) AS global_moderator
    FROM (
        SELECT
            room,
            "user",
            CASE WHEN visible_mod THEN 3 ELSE 2 END AS visible_mod,
            admin,
            TRUE AS room_moderator,
            FALSE AS global_moderator
        FROM user_permission_overrides WHERE moderator

        UNION ALL

        SELECT
            rooms.id AS room,
            users.id as "user",
            CASE WHEN visible_mod THEN 1 ELSE 0 END AS visible_mod,
            admin,
            FALSE as room_moderator,
            TRUE as global_moderator
        FROM users CROSS JOIN rooms WHERE moderator
    ) m GROUP BY "user", room
) mods JOIN users on "user" = users.id;


-- Scheduled changes to user permissions.  For example, to implement a 2-day timeout you would set
-- their user_permissions.write to false, then set a `write = true` entry with a +2d timestamp here.
-- Or to implement a join delay you could set room defaults to false then insert a value here to be
-- applied after a delay.
CREATE TABLE user_permission_futures (
    room BIGINT NOT NULL REFERENCES rooms ON DELETE CASCADE,
    "user" BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    at FLOAT NOT NULL, /* when the change should take effect (unix epoch) */
    read BOOLEAN, /* Set this value @ at, if non-null */
    write BOOLEAN, /* Set this value @ at, if non-null */
    upload BOOLEAN /* Set this value @ at, if non-null */
);
CREATE INDEX user_permissions_future_at ON user_permission_futures(at);
CREATE INDEX user_permissions_future_room_user ON user_permission_futures(room, "user");

-- Similar to the above, but for ban/unbans.  For example to implement a 2-day ban you would set
-- their user_permissions.banned to TRUE then add a row here with banned = FALSE to schedule the
-- unban.  (You can also schedule a future *ban* here, but the utility of that is less clear).
CREATE TABLE user_ban_futures (
    room BIGINT REFERENCES rooms ON DELETE CASCADE,
    "user" BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    at FLOAT NOT NULL, /* when the change should take effect (unix epoch) */
    banned BOOLEAN NOT NULL /* if true then ban at `at`, if false then unban */
);
CREATE INDEX user_ban_futures_at ON user_ban_futures(at);
CREATE INDEX user_ban_futures_room_user ON user_ban_futures(room, "user");


-- Nonce tracking to prohibit request signature nonce reuse (thus prevent replay attacks)
CREATE TABLE user_request_nonces (
    "user" BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    nonce BYTEA NOT NULL UNIQUE,
    expiry FLOAT NOT NULL DEFAULT (extract(epoch from now() + '24 hours'))
);
CREATE INDEX user_request_nonces_expiry ON user_request_nonces(expiry);



CREATE TABLE inbox (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    recipient BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    sender BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
    body BYTEA NOT NULL,
    posted_at FLOAT DEFAULT (extract(epoch from now())),
    expiry FLOAT DEFAULT (extract(epoch from now() + '15 days'))
);
CREATE INDEX inbox_recipient ON inbox(recipient);


COMMIT;
