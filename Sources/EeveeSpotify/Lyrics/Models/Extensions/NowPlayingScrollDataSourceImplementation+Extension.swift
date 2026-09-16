import Orion

extension NowPlayingScrollDataSourceImplementation {
    var activeProviders: Array<AnyObject> {
        get {
            Ivars<Array<AnyObject>>(self).activeProviders
        }
        set {
            Ivars<Array<AnyObject>>(self).activeProviders = newValue
        }
    }
}
