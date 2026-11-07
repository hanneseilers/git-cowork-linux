// C side of the Linux app: GTK 4, libadwaita, libsecret, plus small helpers
// for things Swift can't express directly (macros, fixed-size structs, varargs).
#ifndef GIT_COWORK_CGTK_SHIM_H
#define GIT_COWORK_CGTK_SHIM_H

#include <gtk/gtk.h>
#include <adwaita.h>
#include <glib-unix.h>
#include <libsecret/secret.h>

// MARK: Secret Service (GNOME Keyring, KWallet) — the Linux "Keychain"

static inline const SecretSchema *gc_secret_schema(void) {
    static const SecretSchema schema = {
        "dev.gitcowork.Secret", SECRET_SCHEMA_NONE,
        {
            { "service", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { "account", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        },
        0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    };
    return &schema;
}

/// Stores `secret` (UTF-8 text) under service/account. Returns 1 on success;
/// on failure `*message` gets an error text the caller frees with g_free.
static inline int gc_secret_store(const char *service, const char *account, const char *label,
                                  const char *secret, char **message) {
    GError *error = NULL;
    gboolean ok = secret_password_store_sync(gc_secret_schema(), SECRET_COLLECTION_DEFAULT, label, secret,
                                             NULL, &error, "service", service, "account", account, NULL);
    if (error) {
        if (message) *message = g_strdup(error->message);
        g_error_free(error);
        return 0;
    }
    return ok ? 1 : 0;
}

/// The stored secret (free with secret_password_free), or NULL.
static inline char *gc_secret_lookup(const char *service, const char *account) {
    GError *error = NULL;
    char *value = secret_password_lookup_sync(gc_secret_schema(), NULL, &error,
                                              "service", service, "account", account, NULL);
    if (error) { g_error_free(error); return NULL; }
    return value;
}

static inline int gc_secret_clear(const char *service, const char *account) {
    GError *error = NULL;
    gboolean ok = secret_password_clear_sync(gc_secret_schema(), NULL, &error,
                                             "service", service, "account", account, NULL);
    if (error) { g_error_free(error); return 0; }
    return ok ? 1 : 0;
}

// MARK: GObject helpers

static inline void gc_object_set_string(gpointer object, const char *property, const char *value) {
    g_object_set(object, property, value, NULL);
}

static inline void gc_object_set_bool(gpointer object, const char *property, gboolean value) {
    g_object_set(object, property, value, NULL);
}

static inline void gc_object_set_int(gpointer object, const char *property, int value) {
    g_object_set(object, property, value, NULL);
}

/// gtk_alert_dialog_new takes a printf format; pass text through "%s".
static inline GtkAlertDialog *gc_alert_dialog_new(const char *message) {
    return gtk_alert_dialog_new("%s", message);
}

static inline AdwDialog *gc_alert_new(const char *heading, const char *body) {
    return adw_alert_dialog_new(heading, body);
}

/// A cairo color helper so Swift code stays short.
static inline void gc_cairo_rgba(cairo_t *cr, double r, double g, double b, double a) {
    cairo_set_source_rgba(cr, r, g, b, a);
}

static inline GType gc_string_object_type(void) { return GTK_TYPE_STRING_OBJECT; }

#endif
