import Foundation

/// Common IRC numeric reply codes. Only the codes the client acts on are
/// enumerated; unknown numerics are still parsed and surfaced as raw strings
/// via `IRCMessage.command`.
public enum IRCNumeric: Int, Sendable {
    // Registration / welcome
    case welcome = 1            // RPL_WELCOME
    case yourHost = 2           // RPL_YOURHOST
    case created = 3            // RPL_CREATED
    case myInfo = 4             // RPL_MYINFO
    case iSupport = 5           // RPL_ISUPPORT

    // User / channel info
    case away = 301             // RPL_AWAY
    case unaway = 305           // RPL_UNAWAY
    case nowAway = 306          // RPL_NOWAWAY
    case whoisUser = 311        // RPL_WHOISUSER
    case whoisServer = 312      // RPL_WHOISSERVER
    case whoisIdle = 317        // RPL_WHOISIDLE
    case endOfWhois = 318       // RPL_ENDOFWHOIS
    case whoisChannels = 319    // RPL_WHOISCHANNELS
    case channelModeIs = 324    // RPL_CHANNELMODEIS
    case topic = 332            // RPL_TOPIC
    case topicWhoTime = 333     // RPL_TOPICWHOTIME
    case whoisBot = 335         // RPL_WHOISBOT
    case namReply = 353         // RPL_NAMREPLY
    case endOfNames = 366       // RPL_ENDOFNAMES
    case motd = 372             // RPL_MOTD
    case motdStart = 375        // RPL_MOTDSTART
    case endOfMotd = 376        // RPL_ENDOFMOTD

    // SASL
    case loggedIn = 900         // RPL_LOGGEDIN
    case loggedOut = 901        // RPL_LOGGEDOUT
    case nickLocked = 902       // ERR_NICKLOCKED
    case saslSuccess = 903      // RPL_SASLSUCCESS
    case saslFail = 904         // ERR_SASLFAIL
    case saslTooLong = 905      // ERR_SASLTOOLONG
    case saslAborted = 906      // ERR_SASLABORTED
    case saslAlready = 907      // ERR_SASLALREADY
    case saslMechs = 908        // RPL_SASLMECHS

    // Errors the client reacts to during registration
    case noNicknameGiven = 431  // ERR_NONICKNAMEGIVEN
    case erroneousNick = 432    // ERR_ERRONEUSNICKNAME
    case nicknameInUse = 433    // ERR_NICKNAMEINUSE
    case nickCollision = 436    // ERR_NICKCOLLISION

    /// `true` for the 900-range SASL completion codes that end authentication.
    public var endsSASL: Bool {
        switch self {
        case .saslSuccess, .saslFail, .saslTooLong, .saslAborted,
             .saslAlready, .nickLocked:
            return true
        default:
            return false
        }
    }
}
