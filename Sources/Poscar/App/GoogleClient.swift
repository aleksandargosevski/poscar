import Foundation
import PoscarCore

/// Poscar's OAuth client from Google Cloud ("Desktop app" type).
///
/// The ID and secret are written into Info.plist by scripts/build.sh, from
/// scripts/google-client.env locally or from repository secrets in CI. They stay out of the
/// repository because GitHub reports Google secrets it finds, and Google then disables them.
enum GoogleClient {
    static let config = GoogleOAuth.Client(
        id: Bundle.main.object(forInfoDictionaryKey: "PoscarGoogleClientID") as? String ?? "",
        secret: Bundle.main.object(forInfoDictionaryKey: "PoscarGoogleClientSecret") as? String ?? ""
    )
}
