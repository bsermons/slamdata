module Controller.File.Common where

import Control.Inject1 (Inject1, inj)
import Control.Monad.Eff (Eff())
import Data.String (joinWith)
import DOM (DOM())
import Model.File.Item (Item(), itemPath)
import Utils (newTab, encodeURIComponent)

-- | Lifts an input value into an applicative and injects it into the right
-- | place in an Either.
toInput :: forall m a b. (Applicative m, Inject1 a b) => a -> m b
toInput = pure <<< inj

-- | Open a notebook or file.
open :: forall e. Item -> Boolean -> Eff (dom :: DOM | e) Unit
open item isNew =
  newTab $ joinWith "" $
    [Config.notebookUrl, "#", itemPath item, "/edit"]
    <> if isNew then ["/?q=", encodeURIComponent ("select * from ...")] else []